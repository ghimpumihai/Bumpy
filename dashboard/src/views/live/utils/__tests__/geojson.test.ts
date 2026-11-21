import { describe, expect, it } from "vitest";

import { liveTrails } from "@/views/live/utils/geojson";

describe("live GeoJSON", () => {
  it("draws a trail only once a segment has two positions", () => {
    const trails = liveTrails({ a: [[[23.59, 46.77]]], b: [[[23.59, 46.77], [23.6, 46.78]]] });
    expect(trails.features.map((f) => f.properties.sessionId)).toEqual(["b"]);
  });
});
