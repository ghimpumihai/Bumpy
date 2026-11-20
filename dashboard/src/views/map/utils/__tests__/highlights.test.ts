import { describe, expect, it } from "vitest";

import type { SegmentAggregate, SegmentCollection } from "@/types/segments";
import { metricScale } from "@/views/map/utils/metric";
import { worstSegments } from "@/views/map/utils/highlights";

const segment = (h3: string, roughness: number | null, potholeConfirmed = false) =>
  ({ h3, roughness, roughnessPctl: null, msi1hPct: null, potholeConfirmed, nSessions: 2 }) as SegmentAggregate;
const collection = (segments: SegmentAggregate[]): SegmentCollection => ({
  type: "FeatureCollection",
  features: segments.map((properties) => ({ type: "Feature", geometry: { type: "Polygon", coordinates: [] }, properties })),
});

describe("worstSegments", () => {
  it("lists confirmed potholes first, then the highest values, skipping segments without a value", () => {
    const data = collection([segment("a", 0.4), segment("b", 1.7), segment("c", null), segment("d", 0.6, true), segment("e", 1.1)]);
    expect(worstSegments(data, metricScale("roughness", "model"), 3).map((s) => s.h3)).toEqual(["d", "b", "e"]);
  });
});
