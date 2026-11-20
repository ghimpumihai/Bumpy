import type { Map as MapLibreMap } from "maplibre-gl";
import type { SegmentAggregate } from "@/types/segments";

/** Which aggregate colours the hexagons. */
export const MapMetric = {
  ROUGHNESS: "roughness",
  SICKNESS: "sickness",
} as const;
export type MapMetric = (typeof MapMetric)[keyof typeof MapMetric];

/** A colour band of a map legend. `max` is exclusive; the last band has `max = null`. */
export interface ScaleBand {
  min: number;
  max: number | null;
  label: string;
  /** CSS custom property holding the colour, e.g. `--scale-1`. */
  colorVar: string;
}

/** Which aggregate colours the hexagons, with its bands and legend text. */
export interface MetricScale {
  /** Property of `SegmentAggregate` that colours the hexagon. */
  property: keyof Pick<SegmentAggregate, "roughness" | "roughnessPctl" | "msi1hPct">;
  bands: ScaleBand[];
  title: string;
  footnote: string;
}

/** The MapLibre instance of a `MapCanvas`, shared with its layers through context. */
export interface MapState {
  map: MapLibreMap;
  /** Increments whenever a style finished loading; a new style drops every source and layer. */
  styleGeneration: number;
}
