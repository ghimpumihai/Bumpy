import { MS_TO_KMH } from "@/constants/units";
import type { SessionChartData } from "@/types/charts";
import type { RoadEventCollection, SessionSeries, SicknessRating } from "@/types/sessions";
import { lowerIndex } from "@/utils/geo";


/** Index of the series sample closest to `timeMs`. */
function nearestIndex(times: number[], timeMs: number): number {
  const i = lowerIndex(times, timeMs);
  return i + 1 < times.length && times[i + 1] - timeMs < timeMs - times[i] ? i + 1 : i;
}

/**
 * Aligns sparse data (events, MISC ratings) onto the ≈ 5 Hz series as point series, which is how uPlot
 * draws markers on a shared x axis.
 */
export function buildChartData(series: SessionSeries, events: RoadEventCollection | undefined, ratings: SicknessRating[]): SessionChartData {
  const n = series.t.length;
  const potholes = new Array<number | null>(n).fill(null);
  const speedBumps = new Array<number | null>(n).fill(null);
  const ratingPoints = new Array<number | null>(n).fill(null);
  if (n > 0) {
    for (const feature of events?.features ?? []) {
      const index = nearestIndex(series.t, Date.parse(feature.properties.tUtc));
      if (feature.properties.type === "pothole") potholes[index] = series.aVert[index];
      if (feature.properties.type === "speed_bump") speedBumps[index] = series.aVert[index];
    }
    for (const rating of ratings) ratingPoints[nearestIndex(series.t, Date.parse(rating.tUtc))] = rating.value;
  }
  return {
    times: series.t,
    aVert: series.aVert,
    potholes,
    speedBumps,
    aLat: series.aLat,
    aLon: series.aLon,
    speedKmh: series.speed.map((v) => (v === null ? null : v * MS_TO_KMH)),
    msdv: series.msdv,
    ratings: ratingPoints,
  };
}
