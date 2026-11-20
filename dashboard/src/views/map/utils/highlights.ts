import type { MetricScale } from "@/types/map";
import type { SegmentAggregate, SegmentCollection } from "@/types/segments";

/**
 * The segments worth looking at first: crowd-confirmed potholes, then the highest values of the metric
 * on screen. Gives keyboard and screen-reader users a way into the segment details without the map.
 */
export function worstSegments(data: SegmentCollection, scale: MetricScale, limit: number): SegmentAggregate[] {
  const value = (segment: SegmentAggregate) => segment[scale.property] ?? -Infinity;
  return data.features
    .map((feature) => feature.properties)
    .filter((segment) => segment.potholeConfirmed || segment[scale.property] !== null)
    .sort((a, b) => Number(b.potholeConfirmed) - Number(a.potholeConfirmed) || value(b) - value(a))
    .slice(0, limit);
}
