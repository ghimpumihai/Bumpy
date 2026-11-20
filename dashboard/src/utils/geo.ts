import { EARTH_RADIUS_M } from "@/constants/units";
import type { Position } from "@/types/common";


const toRad = (deg: number) => (deg * Math.PI) / 180;
const toDeg = (rad: number) => (rad * 180) / Math.PI;

export function haversineM(a: Position, b: Position): number {
  const dLat = toRad(b[1] - a[1]);
  const dLon = toRad(b[0] - a[0]);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a[1])) * Math.cos(toRad(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Initial bearing from `a` to `b`, degrees clockwise from north, 0–360. */
export function bearingDeg(a: Position, b: Position): number {
  const φ1 = toRad(a[1]);
  const φ2 = toRad(b[1]);
  const Δλ = toRad(b[0] - a[0]);
  const y = Math.sin(Δλ) * Math.cos(φ2);
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

/** Signed smallest difference `b − a` between two bearings, −180…180. */
export function bearingDelta(a: number, b: number): number {
  return ((b - a + 540) % 360) - 180;
}

/** Cumulative distance (m) at every vertex of a polyline; first entry is 0. */
export function cumulativeDistances(line: Position[]): number[] {
  const out = [0];
  for (let i = 1; i < line.length; i++) out.push(out[i - 1] + haversineM(line[i - 1], line[i]));
  return out;
}

/** Index of the last element `<= value` in an ascending array (binary search), clamped to the array. */
export function lowerIndex(sorted: number[], value: number): number {
  let lo = 0;
  let hi = sorted.length - 1;
  if (value <= sorted[0]) return 0;
  if (value >= sorted[hi]) return hi;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (sorted[mid] <= value) lo = mid;
    else hi = mid;
  }
  return lo;
}

/** Point at distance `s` (m) along a polyline, linearly interpolated. */
export function pointAtDistance(line: Position[], cumulative: number[], s: number): Position {
  const i = lowerIndex(cumulative, s);
  if (i >= line.length - 1) return line[line.length - 1];
  const span = cumulative[i + 1] - cumulative[i];
  const f = span > 0 ? (s - cumulative[i]) / span : 0;
  return [line[i][0] + (line[i + 1][0] - line[i][0]) * f, line[i][1] + (line[i + 1][1] - line[i][1]) * f];
}

/** Bounding box `[[minLon, minLat], [maxLon, maxLat]]` of a set of positions. */
export function boundsOf(points: Position[]): [Position, Position] | null {
  if (points.length === 0) return null;
  let minLon = Infinity;
  let minLat = Infinity;
  let maxLon = -Infinity;
  let maxLat = -Infinity;
  for (const [lon, lat] of points) {
    minLon = Math.min(minLon, lon);
    minLat = Math.min(minLat, lat);
    maxLon = Math.max(maxLon, lon);
    maxLat = Math.max(maxLat, lat);
  }
  return [
    [minLon, minLat],
    [maxLon, maxLat],
  ];
}
