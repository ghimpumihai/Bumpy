import { describe, expect, it } from "vitest";

import type { LiveDevice } from "@/types/live";
import { livePositions, liveTracks } from "@/views/live/utils/geojson";

const device = (deviceId: string, track: [number, number][]): LiveDevice => ({
  deviceId,
  sessionId: "s",
  source: "live",
  sessionStatus: "live",
  vehicleType: "car",
  updatedAt: "2026-11-20T10:00:00.000Z",
  receivedAt: "2026-11-20T10:00:02.500Z",
  latestRating: null,
  lat: 46.77,
  lon: 23.59,
  speedMs: 10,
  courseDeg: 90,
  hAccM: 4,
  roughnessNow: 0.3,
  msdvSoFar: 1,
  battery: 0.8,
  thermal: "nominal",
  track,
});

describe("live GeoJSON", () => {
  it("draws a track only once a device has two positions", () => {
    const tracks = liveTracks([device("a", [[23.59, 46.77]]), device("b", [[23.59, 46.77], [23.6, 46.78]])]);
    expect(tracks.features.map((f) => f.properties.deviceId)).toEqual(["b"]);
  });
  it("puts every device's current position on the map", () => {
    const points = livePositions([device("a", []), { ...device("r", []), source: "replay" }]);
    expect(points.features.map((f) => [f.properties.deviceId, f.properties.source, f.geometry.coordinates])).toEqual([
      ["a", "live", [23.59, 46.77]],
      ["r", "replay", [23.59, 46.77]],
    ]);
  });
});
