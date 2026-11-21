import type { Map as MapLibreMap } from "maplibre-gl";

/** A colour band of a map legend. `max` is exclusive; the last band has `max = null`. */
export interface ScaleBand {
  min: number;
  max: number | null;
  label: string;
  /** CSS custom property holding the colour, e.g. `--scale-1`. */
  colorVar: string;
}

/** The MapLibre instance of a `MapCanvas`, shared with its layers through context. */
export interface MapState {
  map: MapLibreMap;
  /** Increments whenever a style finished loading; a new style drops every source and layer. */
  styleGeneration: number;
}
