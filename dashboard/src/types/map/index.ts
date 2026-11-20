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
