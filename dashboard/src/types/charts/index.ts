/** One y-series of a time-series chart. */
export interface ChartSeries {
  label: string;
  /** CSS custom property of the line colour, e.g. `--chart-1`. */
  colorVar: string;
  values: (number | null)[];
  /** Draw points only (sparse markers such as events). */
  pointsOnly?: boolean;
  /** Secondary y axis on the right. */
  axis?: "left" | "right";
  unit?: string;
}

/** A session's series plus sparse markers aligned onto the same time axis. */
export interface SessionChartData {
  times: number[];
  aVert: number[];
  potholes: (number | null)[];
  speedBumps: (number | null)[];
  aLat: number[];
  aLon: number[];
  speedKmh: (number | null)[];
  msdv: number[];
}
