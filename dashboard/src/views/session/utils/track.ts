import type { FeatureCollection, LineString } from "geojson";

import { MS_TO_KMH } from "@/constants/units";
import type { SessionTrack, TrackPieceProperties } from "@/types/sessions";

/** Splits the track into 2-point pieces so each can be coloured by its speed. */
export function trackPieces(track: SessionTrack): FeatureCollection<LineString, TrackPieceProperties> {
  const { coordinates } = track.geometry;
  const { speeds } = track.properties;
  const features = [];
  for (let i = 1; i < coordinates.length; i++) {
    const speed = speeds[i];
    features.push({
      type: "Feature" as const,
      geometry: { type: "LineString" as const, coordinates: [coordinates[i - 1], coordinates[i]] },
      properties: { speedKmh: speed === null ? null : speed * MS_TO_KMH },
    });
  }
  return { type: "FeatureCollection", features };
}
