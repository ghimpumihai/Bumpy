import type { MapMetric, ScaleBand } from "@/types/map";

/**
 * H3 resolution of road segments. Resolution 11 has an average edge of 24.9 m, the "about 25 m"
 * hexagons of plan 02 §8. The backend owns this; the dashboard only needs it for mock data.
 */
export const H3_RESOLUTION = 11;

/** OpenFreeMap vector tiles, no key needed (plan 02 §5, research notes "Dashboard"). */
export const MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/positron";

/** Cluj-Napoca city centre. */
export const DEFAULT_MAP_CENTER: [number, number] = [23.5935, 46.7675];
export const DEFAULT_MAP_ZOOM = 13.2;
export const FIT_BOUNDS_PADDING_PX = 48;
export const FIT_BOUNDS_MAX_ZOOM = 16;

/**
 * Roughness bands use the ISO 2631-1 comfort scale for vertical RMS acceleration (m/s²), which
 * applies to the model-normalized roughness.
 */
export const ROUGHNESS_BANDS: ScaleBand[] = [
  { min: 0, max: 0.315, label: "Smooth (< 0.32 m/s²)", colorVar: "--scale-1" },
  { min: 0.315, max: 0.63, label: "A little rough (0.32–0.63)", colorVar: "--scale-2" },
  { min: 0.63, max: 1, label: "Fairly rough (0.63–1.0)", colorVar: "--scale-3" },
  { min: 1, max: 1.6, label: "Rough (1.0–1.6)", colorVar: "--scale-4" },
  { min: 1.6, max: null, label: "Very rough (> 1.6 m/s²)", colorVar: "--scale-5" },
];

/** Fallback when roughness is only comparable as per-session percentiles (plan 02 §9). */
export const ROUGHNESS_PERCENTILE_BANDS: ScaleBand[] = [
  { min: 0, max: 0.2, label: "Smoothest 20 %", colorVar: "--scale-1" },
  { min: 0.2, max: 0.4, label: "20–40 %", colorVar: "--scale-2" },
  { min: 0.4, max: 0.6, label: "40–60 %", colorVar: "--scale-3" },
  { min: 0.6, max: 0.8, label: "60–80 %", colorVar: "--scale-4" },
  { min: 0.8, max: null, label: "Roughest 20 %", colorVar: "--scale-5" },
];

/** Predicted motion sickness incidence after one hour of this motion (MSDV / 3, ISO 2631-1). */
export const SICKNESS_BANDS: ScaleBand[] = [
  { min: 0, max: 2, label: "< 2 % may vomit / h", colorVar: "--scale-1" },
  { min: 2, max: 5, label: "2–5 %", colorVar: "--scale-2" },
  { min: 5, max: 10, label: "5–10 %", colorVar: "--scale-3" },
  { min: 10, max: 20, label: "10–20 %", colorVar: "--scale-4" },
  { min: 20, max: null, label: "> 20 % may vomit / h", colorVar: "--scale-5" },
];

export const METRIC_LABELS: Record<MapMetric, string> = {
  roughness: "Road roughness",
  sickness: "Motion sickness",
};
