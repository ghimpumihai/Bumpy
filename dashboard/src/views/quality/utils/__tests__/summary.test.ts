import { describe, expect, it } from "vitest";

import { getDataset, qualityRow } from "@/mock/dataset";
import { longestMotionGap, totalInvalidSeconds, worstMotionRate } from "@/views/quality/utils/summary";

describe("quality summaries", () => {
  const degraded = getDataset().sims.get("4e2c8a6f-9b1d-4f3e-a0c7-5d8b2e6f9c43");
  if (!degraded) throw new Error("degraded mock session missing");
  const row = qualityRow(degraded);

  it("reports the worst motion stream", () => {
    expect(worstMotionRate(row)).toBeLessThanOrEqual(row.quality.streams.device_motion.rateHz ?? Infinity);
    expect(longestMotionGap(row)).toBeGreaterThan(1);
  });

  it("adds up invalid time over every reason", () => {
    const { invalidSeconds } = row.quality;
    expect(totalInvalidSeconds(row)).toBe(
      invalidSeconds.phone_moved + invalidSeconds.gravity_drift + invalidSeconds.gyro_gps_mismatch + invalidSeconds.gps_poor,
    );
  });
});
