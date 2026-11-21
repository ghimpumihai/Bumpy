import type { SegmentAggregate, SegmentCollection } from "@/types/segments";

/**
 * The segments worth looking at first: crowd-confirmed potholes, then the most-driven. Gives keyboard and
 * screen-reader users a way into the segment details without the map.
 */
export function busiestSegments(data: SegmentCollection, limit: number): SegmentAggregate[] {
  return data.features
    .map((feature) => feature.properties)
    .sort((a, b) => Number(b.potholeConfirmed) - Number(a.potholeConfirmed) || b.nSessions - a.nSessions)
    .slice(0, limit);
}

/** The heat map's colour for a segment driven by `trips` trips (violet at 1, pink at about 6, orange from 12). */
export function heatColor(trips: number): string {
  if (trips <= 6) return `color-mix(in srgb, var(--heat-mid) ${Math.round(((Math.max(trips, 1) - 1) / 5) * 100)}%, var(--heat-low))`;
  return `color-mix(in srgb, var(--heat) ${Math.round((Math.min(trips - 6, 6) / 6) * 100)}%, var(--heat-mid))`;
}
