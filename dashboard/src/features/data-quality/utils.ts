import { STREAM_GAP_MISSED_SAMPLES, STREAM_GAP_PROBLEM_S, STREAM_RATE_WARN_RATIO } from "@/constants/sessions";
import { StreamStatus, type StreamQuality } from "@/types/sessions";

/**
 * The longest normal pause of a stream: 1 s for the 100 Hz motion streams (spec §7), but several
 * sample periods for slow streams, whose normal spacing is already ≥ 1 s.
 */
export function gapLimitSeconds(expectedHz: number | null): number {
  if (expectedHz === null || expectedHz <= 0) return STREAM_GAP_PROBLEM_S;
  return Math.max(STREAM_GAP_PROBLEM_S, STREAM_GAP_MISSED_SAMPLES / expectedHz);
}

/** `problem` if the stream paused longer than its gap limit, `warn` if its rate is below 90 % of expected. */
export function streamStatus(stream: StreamQuality): StreamStatus {
  if ((stream.maxGapS ?? 0) > gapLimitSeconds(stream.expectedHz)) return StreamStatus.PROBLEM;
  if (stream.rateHz !== null && stream.expectedHz !== null && stream.rateHz < stream.expectedHz * STREAM_RATE_WARN_RATIO) {
    return StreamStatus.WARN;
  }
  return StreamStatus.OK;
}
