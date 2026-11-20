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

/** Slow streams (≈1 Hz GPS, 0.2 Hz device health) need more decimals to show their rate meaningfully. */
const SLOW_STREAM_HZ = 2;
export const rateDigits = (expectedHz: number | null) => (expectedHz !== null && expectedHz < SLOW_STREAM_HZ ? 2 : 1);
/** Expected rates are whole numbers except for sub-1 Hz streams (0.2 Hz). */
export const expectedRateDigits = (expectedHz: number) => (Number.isInteger(expectedHz) ? 0 : 1);
