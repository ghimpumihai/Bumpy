import { describe, expect, it } from "vitest";

import type { SegmentAggregate, SegmentCollection } from "@/types/segments";
import { busiestSegments } from "@/views/map/utils/highlights";

const segment = (h3: string, nSessions: number, potholeConfirmed = false) => ({ h3, nSessions, potholeConfirmed }) as SegmentAggregate;
const collection = (segments: SegmentAggregate[]): SegmentCollection => ({
  type: "FeatureCollection",
  features: segments.map((properties) => ({ type: "Feature", geometry: { type: "Polygon", coordinates: [] }, properties })),
});

describe("busiestSegments", () => {
  it("lists confirmed potholes first, then the most-driven segments", () => {
    const data = collection([segment("a", 2), segment("b", 9), segment("c", 1, true), segment("d", 5)]);
    expect(busiestSegments(data, 3).map((s) => s.h3)).toEqual(["c", "b", "d"]);
  });
});
