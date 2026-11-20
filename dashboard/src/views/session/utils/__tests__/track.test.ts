import { describe, expect, it } from "vitest";

import { trackPieces } from "@/views/session/utils/track";

describe("trackPieces", () => {
  it("splits a track into coloured pieces with their speed in km/h", () => {
    const pieces = trackPieces({
      type: "Feature",
      geometry: { type: "LineString", coordinates: [[0, 0], [0, 1], [0, 2]] },
      properties: { sessionId: "s", times: [0, 1, 2], speeds: [10, null, 5], trimmedM: 200 },
    });
    expect(pieces.features).toHaveLength(2);
    expect(pieces.features.map((f) => f.properties.speedKmh)).toEqual([null, 18]);
  });
});
