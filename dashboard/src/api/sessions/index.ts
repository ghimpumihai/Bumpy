import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { LIVE_SESSION_POLL_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import { ProcessingStatus } from "@/types/common";
import type {
  RoadEventCollection,
  SessionDetail,
  SessionLabel,
  SessionLabelsResponse,
  SessionListFilters,
  SessionListResponse,
  SessionSeries,
  SessionSummary,
  SessionTrack,
} from "@/types/sessions";
import { expectShape, shapes } from "@/utils/api-shape";

export const SESSIONS_QUERY_KEY = "sessions";

const SESSIONS_ROUTE = "/api/sessions";
const sessionRoute = (sessionId: string, part = "") => `${SESSIONS_ROUTE}/${encodeURIComponent(sessionId)}${part}`;

async function getJson<T>(route: string, check: Parameters<typeof expectShape>[2], params?: object): Promise<T> {
  return expectShape<T>((await api.get<unknown>(route, { params })).data, route, check);
}

const getSessions = async (filters: SessionListFilters): Promise<SessionSummary[]> =>
  (await getJson<SessionListResponse>(SESSIONS_ROUTE, shapes.sessionList, filters)).sessions;
const getSession = (sessionId: string) => getJson<SessionDetail>(sessionRoute(sessionId), shapes.sessionDetail);
const getSeries = (sessionId: string) => getJson<SessionSeries>(sessionRoute(sessionId, "/series"), shapes.series);
const getTrack = (sessionId: string) => getJson<SessionTrack>(sessionRoute(sessionId, "/track"), shapes.track);
const getEvents = (sessionId: string) => getJson<RoadEventCollection>(sessionRoute(sessionId, "/events"), shapes.featureCollection);
const getLabels = async (sessionId: string): Promise<SessionLabel[]> =>
  (await getJson<SessionLabelsResponse>(sessionRoute(sessionId, "/labels"), shapes.labels)).labels;

const isFinalized = (status: ProcessingStatus | undefined) => status === ProcessingStatus.COMPLETE;
/** Recording and processing trips are re-polled until they are finalized; finalized ones never change. */
const pollUntilFinalized = (finalized: boolean) => (finalized ? false : LIVE_SESSION_POLL_INTERVAL_MS);

/**
 * The trip's own data (series, track, events, labels) is keyed by whether the trip is finalized: when the
 * finalize job replaces the live results, the key changes and everything is fetched once more — without
 * that, the page would keep showing the live-path data under a "finalized" header.
 */
const tripDataQuery = <T,>(part: string, sessionId: string, status: ProcessingStatus, fetch: (id: string) => Promise<T>) => ({
  queryKey: [SESSIONS_QUERY_KEY, part, sessionId, isFinalized(status)],
  queryFn: () => fetch(sessionId),
  staleTime: STATIC_STALE_TIME_MS,
  // Only a trip being recorded grows; a processing trip changes once, when it is finalized.
  refetchInterval: status === ProcessingStatus.LIVE ? LIVE_SESSION_POLL_INTERVAL_MS : (false as const),
});

const useSessions = (filters: SessionListFilters = {}) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "list", filters],
    queryFn: () => getSessions(filters),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: (query) => pollUntilFinalized(query.state.data?.every((session) => isFinalized(session.status)) ?? true),
  });

const useSession = (sessionId: string) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "detail", sessionId],
    queryFn: () => getSession(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: (query) => pollUntilFinalized(query.state.data ? isFinalized(query.state.data.status) : true),
  });

const useSessionSeries = (sessionId: string, status: ProcessingStatus) => useQuery(tripDataQuery("series", sessionId, status, getSeries));
const useSessionTrack = (sessionId: string, status: ProcessingStatus) => useQuery(tripDataQuery("track", sessionId, status, getTrack));
const useSessionEvents = (sessionId: string, status: ProcessingStatus) => useQuery(tripDataQuery("events", sessionId, status, getEvents));
const useSessionLabels = (sessionId: string, status: ProcessingStatus) => useQuery(tripDataQuery("labels", sessionId, status, getLabels));

export const sessionsApi = {
  getSessions,
  getSession,
  useSessions,
  useSession,
  useSessionSeries,
  useSessionTrack,
  useSessionEvents,
  useSessionLabels,
};
