import type { ScaleBand } from "@/types/map";

export const TRACK_SOURCE_ID = "session-track";
export const TRACK_EVENTS_SOURCE_ID = "session-events";
export const TRACK_LINE_WIDTH_PX = 4;
export const CHART_HEIGHT_PX = 170;
/** Most recent MISC ratings listed next to the prediction. */
export const MAX_RATING_ROWS = 12;

/** Track colour by speed, km/h. */
export const SPEED_BANDS: ScaleBand[] = [
  { min: 0, max: 10, label: "< 10 km/h", colorVar: "--scale-5" },
  { min: 10, max: 20, label: "10–20", colorVar: "--scale-4" },
  { min: 20, max: 30, label: "20–30", colorVar: "--scale-3" },
  { min: 30, max: 45, label: "30–45", colorVar: "--scale-2" },
  { min: 45, max: null, label: "> 45 km/h", colorVar: "--scale-1" },
];
