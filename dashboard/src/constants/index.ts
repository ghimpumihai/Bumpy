import { MS_PER_SECOND, SECONDS_PER_MINUTE } from "@/constants/units";

/** Static data (aggregates, finished sessions) changes only when a new session is processed. */
export const STATIC_STALE_TIME_MS = 5 * SECONDS_PER_MINUTE * MS_PER_SECOND;
export const DEFAULT_GC_TIME_MS = 15 * SECONDS_PER_MINUTE * MS_PER_SECOND;
/** The live view polls the read API every 2–5 s (plan 02 §5). */
export const LIVE_POLL_INTERVAL_MS = 2 * MS_PER_SECOND;
export const LIVE_SESSION_POLL_INTERVAL_MS = 5 * MS_PER_SECOND;
/** A "live" trip silent for this long is about to be closed by the processor (plan §5: 15 min); check it slowly. */
export const SILENT_LIVE_SESSION_AFTER_MS = 20 * SECONDS_PER_MINUTE * MS_PER_SECOND;
export const SILENT_LIVE_SESSION_POLL_INTERVAL_MS = 60 * MS_PER_SECOND;
/** A trip being processed changes once, when the finalize job is done; check it every half minute… */
export const PROCESSING_SESSION_POLL_INTERVAL_MS = 30 * MS_PER_SECOND;
/** …but only for a while: a trip still processing hours after it ended won't finish while the page is open. */
export const PROCESSING_SESSION_POLL_FOR_MS = 2 * 60 * SECONDS_PER_MINUTE * MS_PER_SECOND;
/** Aggregates change whenever a trip is finalized; refresh them while the page is open. */
export const AGGREGATE_REFRESH_INTERVAL_MS = 60 * MS_PER_SECOND;
export const API_TIMEOUT_MS = 15 * MS_PER_SECOND;
/** The live poll must answer well within a few poll intervals. */
export const LIVE_REQUEST_TIMEOUT_MS = 4 * MS_PER_SECOND;
/** The read API counts as unreachable for the live view when its last good answer is older than this. */
export const LIVE_API_STALE_MS = 3 * LIVE_POLL_INTERVAL_MS;
export const QUERY_RETRY_COUNT = 2;

export const RUNTIME_CONFIG_PATH = "/config.json";
/** Query parameter that forces mock data (`?mock=1`) or the API (`?mock=0`). */
export const MOCK_QUERY_PARAM = "mock";
/** localStorage key of the data-source override set in the settings dialog. */
export const DATA_SOURCE_STORAGE_KEY = "dashboard.data-source";
/** sessionStorage key remembering `?mock=` for the tab. */
export const DATA_SOURCE_SESSION_KEY = "dashboard.forced-mock";
export const RUNTIME_CONFIG_TIMEOUT_MS = 5 * MS_PER_SECOND;

export const PLACEHOLDER = "—";
export const GENERIC_ERROR_MESSAGE = "Something went wrong while loading data.";
