import { describe, expect, it } from "vitest";

import { gapLimitSeconds, streamStatus } from "@/features/data-quality/utils";
import type { StreamQuality } from "@/types/sessions";

const stream = (patch: Partial<StreamQuality>): StreamQuality => ({ rows: 1000, rateHz: 99.8, expectedHz: 100, maxGapS: 0.02, gapsOver1s: 0, ...patch });

describe("streamStatus", () => {
  it("flags motion gaps longer than 1 s and low motion rates", () => {
    expect(streamStatus(stream({}))).toBe("ok");
    expect(streamStatus(stream({ maxGapS: 1.42, gapsOver1s: 2 }))).toBe("problem");
    expect(streamStatus(stream({ rateHz: 85 }))).toBe("warn");
  });

  it("judges slow streams by their own sample period", () => {
    // Normal 1 Hz GPS and 0.2 Hz device health must not show as red "Gaps".
    expect(streamStatus(stream({ rateHz: 1, expectedHz: 1, maxGapS: 2.8 }))).toBe("ok");
    expect(streamStatus(stream({ rateHz: 0.2, expectedHz: 0.2, maxGapS: 12 }))).toBe("ok");
    expect(streamStatus(stream({ rateHz: 0.4, expectedHz: 1, maxGapS: 14.2 }))).toBe("problem");
  });

  it("uses at least 1 s as the gap limit", () => {
    expect(gapLimitSeconds(100)).toBe(1);
    expect(gapLimitSeconds(1)).toBe(3);
    expect(gapLimitSeconds(null)).toBe(1);
  });
});
