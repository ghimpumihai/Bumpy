import {
  LIVE_SESSION_POLL_INTERVAL_MS,
  PROCESSING_SESSION_POLL_FOR_MS,
  PROCESSING_SESSION_POLL_INTERVAL_MS,
  SILENT_LIVE_SESSION_AFTER_MS,
  SILENT_LIVE_SESSION_POLL_INTERVAL_MS,
} from "@/constants";
import { MS_PER_SECOND } from "@/constants/units";
import { ProcessingStatus } from "@/types/common";
import type { SessionSummary } from "@/types/sessions";

type PolledSession = Pick<SessionSummary, "status" | "startedAt" | "endedAt" | "durationS">;

/** Time of the trip's last data: its end once known, else start + duration so far. */
function lastDataMs(session: PolledSession): number {
  if (session.endedAt) return Date.parse(session.endedAt);
  return Date.parse(session.startedAt) + session.durationS * MS_PER_SECOND;
}

/**
 * How often a session's data should be re-fetched, or `false` when it won't change while the page is open.
 * - recording: every 5 s, slowing to once a minute when the phone has gone silent (the processor closes the
 *   trip after 15 min without batches);
 * - processing: every 30 s while the finalize job can plausibly still be running;
 * - finalized: never.
 */
export function sessionPollInterval(session: PolledSession, now: number = Date.now()): number | false {
  const sinceLastData = now - lastDataMs(session);
  switch (session.status) {
    case ProcessingStatus.COMPLETE:
      return false;
    case ProcessingStatus.PROCESSING:
      return sinceLastData < PROCESSING_SESSION_POLL_FOR_MS ? PROCESSING_SESSION_POLL_INTERVAL_MS : false;
    case ProcessingStatus.LIVE:
      return sinceLastData < SILENT_LIVE_SESSION_AFTER_MS ? LIVE_SESSION_POLL_INTERVAL_MS : SILENT_LIVE_SESSION_POLL_INTERVAL_MS;
  }
}

/** The list polls as often as its most active session needs. */
export function sessionListPollInterval(sessions: readonly PolledSession[], now: number = Date.now()): number | false {
  let best: number | false = false;
  for (const session of sessions) {
    const interval = sessionPollInterval(session, now);
    if (interval !== false && (best === false || interval < best)) best = interval;
  }
  return best;
}
