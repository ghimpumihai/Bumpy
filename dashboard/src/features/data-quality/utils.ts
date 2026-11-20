import { STREAM_GAP_PROBLEM_S, STREAM_RATE_WARN_RATIO } from "@/constants/sessions";
import type { StreamQuality } from "@/types/sessions";

export type StreamStatus = "ok" | "warn" | "problem";

/** `ok` | `warn` (rate below 90 % of expected) | `problem` (gaps over 1 s), as on the phone's summary screen. */
export function streamStatus(stream: StreamQuality): StreamStatus {
  if (stream.gapsOver1s > 0 || (stream.maxGapS ?? 0) > STREAM_GAP_PROBLEM_S) return "problem";
  if (stream.rateHz !== null && stream.expectedHz !== null && stream.rateHz < stream.expectedHz * STREAM_RATE_WARN_RATIO) return "warn";
  return "ok";
}

