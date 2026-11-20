import type { ScaleBand } from "@/types/map";

/** The band a value falls in (`min` inclusive, `max` exclusive), or `null` for missing values. */
export function bandFor(bands: ScaleBand[], value: number | null | undefined): ScaleBand | null {
  if (value === null || value === undefined || !Number.isFinite(value)) return null;
  return bands.find((band) => value >= band.min && (band.max === null || value < band.max)) ?? bands[bands.length - 1];
}

/**
 * A MapLibre `step` expression colouring `property` by `bands`; features without a value get `missingColor`.
 * `colors` holds the resolved colour of each band, in order.
 */
export function stepColorExpression(property: string, bands: ScaleBand[], colors: string[], missingColor: string) {
  const steps: (string | number)[] = [colors[0]];
  bands.slice(1).forEach((band, i) => steps.push(band.min, colors[i + 1]));
  return [
    "case",
    ["==", ["typeof", ["get", property]], "number"],
    ["step", ["get", property], ...steps],
    missingColor,
  ] as const;
}
