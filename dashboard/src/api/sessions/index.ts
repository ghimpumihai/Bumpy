import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { LIVE_SESSION_POLL_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import { ProcessingStatus } from "@/types/common";
import type {
  RoadEventCollection,
  SessionDetail,
  SessionLabelsResponse,
  SessionListFilters,
  SessionListResponse,
  SessionSeries,
  SessionTrack,
} from "@/types/sessions";

export const SESSIONS_QUERY_KEY = "sessions";

const sessionPath = (sessionId: string, part = "") => `/api/sessions/${encodeURIComponent(sessionId)}${part}`;

const getSessions = async (filters: SessionListFilters) =>
  (await api.get<SessionListResponse>("/api/sessions", { params: filters })).data.sessions;
const getSession = async (sessionId: string) => (await api.get<SessionDetail>(sessionPath(sessionId))).data;
const getSeries = async (sessionId: string) => (await api.get<SessionSeries>(sessionPath(sessionId, "/series"))).data;
const getTrack = async (sessionId: string) => (await api.get<SessionTrack>(sessionPath(sessionId, "/track"))).data;
const getEvents = async (sessionId: string) => (await api.get<RoadEventCollection>(sessionPath(sessionId, "/events"))).data;
const getLabels = async (sessionId: string) =>
  (await api.get<SessionLabelsResponse>(sessionPath(sessionId, "/labels"))).data.labels;

/** Finalized sessions never change; recording and processing ones are re-polled until they are finalized. */
const pollUntilFinalized = (finalized: boolean) => (finalized ? false : LIVE_SESSION_POLL_INTERVAL_MS);
const isFinalized = (status: ProcessingStatus | undefined) => status === ProcessingStatus.COMPLETE;

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

const useSessionSeries = (sessionId: string, finalized: boolean) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "series", sessionId],
    queryFn: () => getSeries(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: pollUntilFinalized(finalized),
  });

const useSessionTrack = (sessionId: string, finalized: boolean) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "track", sessionId],
    queryFn: () => getTrack(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: pollUntilFinalized(finalized),
  });

const useSessionEvents = (sessionId: string, finalized: boolean) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "events", sessionId],
    queryFn: () => getEvents(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: pollUntilFinalized(finalized),
  });

const useSessionLabels = (sessionId: string, finalized: boolean) =>
  useQuery({
    queryKey: [SESSIONS_QUERY_KEY, "labels", sessionId],
    queryFn: () => getLabels(sessionId),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: pollUntilFinalized(finalized),
  });

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
