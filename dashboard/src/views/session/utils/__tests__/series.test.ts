import { describe, expect, it } from "vitest";

import type { RoadEventCollection, SessionSeries } from "@/types/sessions";
import { buildChartData } from "@/views/session/utils/series";

const T0 = Date.parse("2026-11-19T13:00:00.000Z");
const series: SessionSeries = {
  t: [T0, T0 + 200, T0 + 400, T0 + 600],
  aVert: [0.1, 5.2, -0.3, 0.2],
  aLat: [0, 0, 0, 0],
  aLon: [0, 0, 0, 0],
  speed: [10, 10, null, 5],
  msdv: [0, 0.1, 0.2, 0.3],
};
const event = (type: "pothole" | "speed_bump", tUtc: string) => ({
  type: "Feature" as const,
  geometry: { type: "Point" as const, coordinates: [23.6, 46.77] },
  properties: { id: tUtc, sessionId: "s", type, tUtc, speedKmh: 30, magnitude: 5, confidence: 0.9, matchedLabel: true, vehicleType: "car" as const },
});

describe("buildChartData", () => {
  it("puts events on the nearest sample of the series", () => {
    const events: RoadEventCollection = {
      type: "FeatureCollection",
      features: [event("pothole", new Date(T0 + 230).toISOString()), event("speed_bump", new Date(T0 + 590).toISOString())],
    };
    const data = buildChartData(series, events);
    expect(data.potholes).toEqual([null, 5.2, null, null]);
    expect(data.speedBumps).toEqual([null, null, null, 0.2]);
  });

  it("converts speed to km/h and keeps gaps", () => {
    expect(buildChartData(series, undefined).speedKmh).toEqual([36, 36, null, 18]);
  });

  it("handles an empty series", () => {
    const empty = buildChartData({ t: [], aVert: [], aLat: [], aLon: [], speed: [], msdv: [] }, undefined);
    expect(empty.potholes).toEqual([]);
  });
});
