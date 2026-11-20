import type { QualityRow } from "@/types/sessions";

/** The core motion streams; the session is only as good as the worst of them. */
const MOTION_STREAMS = ["device_motion", "accel_raw", "gyro_raw"] as const;

export function worstMotionRate(row: QualityRow): number | null {
  const rates = MOTION_STREAMS.flatMap((name) => {
    const rate = row.quality.streams[name]?.rateHz;
    return rate === null || rate === undefined ? [] : [rate];
  });
  return rates.length > 0 ? Math.min(...rates) : null;
}

export function longestMotionGap(row: QualityRow): number | null {
  const gaps = MOTION_STREAMS.flatMap((name) => {
    const gap = row.quality.streams[name]?.maxGapS;
    return gap === null || gap === undefined ? [] : [gap];
  });
  return gaps.length > 0 ? Math.max(...gaps) : null;
}

export function totalInvalidSeconds(row: QualityRow): number {
  return Object.values(row.quality.invalidSeconds).reduce((sum, seconds) => sum + seconds, 0);
}
