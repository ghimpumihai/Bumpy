import { type Query, useQueries, useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { STATIC_STALE_TIME_MS } from "@/constants";
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
import { sessionListPollInterval, sessionPollInterval } from "@/utils/session-polling";

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

/** What the trip-data hooks need from the session: its id, and enough to know whether it still changes. */
type TripRef = Pick<SessionSummary, "sessionId" | "status" | "startedAt" | "endedAt" | "durationS">;

/**
 * The trip's own data (series, track, events, labels) is keyed by the trip's status: each transition
 * (recording → processing when the last batch is in, processing → finalized when the finalize job replaces
 * the live results) changes the key, so everything is fetched once more. Without that, the page would keep
 * the data of the last poll before the trip ended, or the live-path data under a "finalized" header.
 */
const tripDataQuery = <T,>(part: string, trip: TripRef, fetch: (id: string) => Promise<T>) => ({
  queryKey: [SESSIONS_QUERY_KEY, part, trip.sessionId, trip.status],
  queryFn: () => fetch(trip.sessionId),
  staleTime: STATIC_STALE_TIME_MS,
  // Keep showing the same trip's data while its next version loads (never another trip's).
  placeholderData: (previous: T | undefined, previousQuery: Query<T, Error, T, readonly unknown[]> | undefined) =>
    previousQuery?.queryKey[2] === trip.sessionId ? previous : undefined,
  // Only a trip being recorded grows; a processing trip changes once, when it is finalized (new key).
  refetchInterval: trip.status === ProcessingStatus.LIVE ? sessionPollInterval(trip) : (false as const),
});

const useSessions = (filters: SessionListFilters = {}) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "list", filters],
    queryFn: () => getSessions(filters),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: (query) => sessionListPollInterval(query.state.data ?? []),
  });

const useSession = (sessionId: string) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "detail", sessionId],
    queryFn: () => getSession(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: (query) => (query.state.data ? sessionPollInterval(query.state.data) : false),
  });

const useSessionSeries = (trip: TripRef) => useQuery(tripDataQuery("series", trip, getSeries));
const useSessionTrack = (trip: TripRef) => useQuery(tripDataQuery("track", trip, getTrack));
/** The tracks of several trips at once (the map's replay), sharing the trip page's cache. */
const useSessionTracks = (trips: TripRef[]) => useQueries({ queries: trips.map((trip) => tripDataQuery("track", trip, getTrack)) });
const useSessionEvents = (trip: TripRef) => useQuery(tripDataQuery("events", trip, getEvents));
const useSessionLabels = (trip: TripRef) => useQuery(tripDataQuery("labels", trip, getLabels));

export const sessionsApi = {
  getSessions,
  getSession,
  useSessions,
  useSession,
  useSessionSeries,
  useSessionTrack,
  useSessionTracks,
  useSessionEvents,
  useSessionLabels,
};
