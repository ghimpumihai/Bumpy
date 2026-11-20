import { MS_PER_SECOND, SECONDS_PER_MINUTE } from "@/constants/units";

/** Static data (aggregates, finished sessions) changes only when a new session is processed. */
export const STATIC_STALE_TIME_MS = 5 * SECONDS_PER_MINUTE * MS_PER_SECOND;
export const DEFAULT_GC_TIME_MS = 15 * SECONDS_PER_MINUTE * MS_PER_SECOND;
/** The live view polls the read API every 2–5 s (plan 02 §5). */
export const LIVE_POLL_INTERVAL_MS = 2 * MS_PER_SECOND;
export const LIVE_SESSION_POLL_INTERVAL_MS = 5 * MS_PER_SECOND;
/** Aggregates change whenever a trip is finalized; refresh them while the page is open. */
export const AGGREGATE_REFRESH_INTERVAL_MS = 60 * MS_PER_SECOND;
export const API_TIMEOUT_MS = 15 * MS_PER_SECOND;
export const QUERY_RETRY_COUNT = 2;

export const RUNTIME_CONFIG_PATH = "/config.json";
/** Query parameter that forces mock data (`?mock=1`) or the API (`?mock=0`). */
export const MOCK_QUERY_PARAM = "mock";
/** localStorage key of the data-source override set in the settings dialog. */
export const DATA_SOURCE_STORAGE_KEY = "dashboard.data-source";

export const PLACEHOLDER = "—";
export const GENERIC_ERROR_MESSAGE = "Something went wrong while loading data.";
