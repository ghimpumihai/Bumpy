import { describe, expect, it } from "vitest";

import { PLACEHOLDER } from "@/constants";
import { formatDuration } from "@/utils/format-date-time";
import { formatDistance, formatFraction, formatPercent, formatSpeedFromMs } from "@/utils/format-number";
import { bearingDelta, cumulativeDistances, haversineM, lowerIndex } from "@/utils/geo";

describe("formatters", () => {
  it("formats durations", () => {
    expect(formatDuration(45)).toBe("45 s");
    expect(formatDuration(750)).toBe("12 min 30 s");
    expect(formatDuration(3900)).toBe("1 h 05 min");
    expect(formatDuration(null)).toBe(PLACEHOLDER);
  });
  it("formats numbers with units", () => {
    expect(formatDistance(850)).toBe("850 m");
    expect(formatDistance(12_400)).toBe("12.4 km");
    expect(formatFraction(0.934)).toBe("93 %");
    expect(formatPercent(4.25)).toBe("4.3 %");
    expect(formatSpeedFromMs(10)).toBe("36 km/h");
    expect(formatPercent(Number.NaN)).toBe(PLACEHOLDER);
  });
});

describe("geo", () => {
  it("measures distances", () => {
    // One degree of latitude is about 111.2 km.
    expect(haversineM([23.6, 46.7], [23.6, 47.7])).toBeCloseTo(111_195, -2);
    expect(cumulativeDistances([[0, 0], [0, 1], [0, 2]]).at(-1)).toBeCloseTo(222_390, -2);
  });
  it("finds the segment of a value and the signed bearing change", () => {
    expect(lowerIndex([0, 10, 20], 15)).toBe(1);
    expect(lowerIndex([0, 10, 20], 99)).toBe(2);
    expect(bearingDelta(350, 10)).toBe(20);
    expect(bearingDelta(10, 350)).toBe(-20);
  });
});
