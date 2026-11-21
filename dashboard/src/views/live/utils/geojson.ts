import type { FeatureCollection, MultiLineString, Point } from "geojson";

import type { Position } from "@/types/common";

export function liveTrails(tails: Record<string, Position[][]>): FeatureCollection<MultiLineString, { sessionId: string }> {
  return {
    type: "FeatureCollection",
    features: Object.entries(tails)
      .map(([sessionId, segments]) => ({ sessionId, segments: segments.filter((segment) => segment.length > 1) }))
      .filter(({ segments }) => segments.length > 0)
      .map(({ sessionId, segments }) => ({
        type: "Feature",
        geometry: { type: "MultiLineString", coordinates: segments },
        properties: { sessionId },
      })),
  };
}

export const EMPTY_PINGS: FeatureCollection<Point, { type: string; age: number }> = { type: "FeatureCollection", features: [] };

export interface LivePing {
  key: string;
  position: Position;
  /** Event type, for the ring colour. */
  type: string;
  startedAt: number;
}

/** The rings still visible at `now`, as points carrying their age (0 → 1). */
export function livePings(pings: LivePing[], now: number, durationMs: number): FeatureCollection<Point, { type: string; age: number }> {
  return {
    type: "FeatureCollection",
    features: pings
      .filter((ping) => now - ping.startedAt < durationMs)
      .map((ping) => ({
        type: "Feature",
        geometry: { type: "Point", coordinates: ping.position },
        properties: { type: ping.type, age: (now - ping.startedAt) / durationMs },
      })),
  };
}
