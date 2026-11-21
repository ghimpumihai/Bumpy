import type { Position } from "@/types/common";

/** About 30 m: a poll whose window still reaches back to the end of the trail continues it. */
const CONTINUES_WITHIN_DEG = 0.0003;

/**
 * The API only sends the last ~2 minutes of a trip's track; appending each poll keeps the whole trail.
 * The windows needn't share exact points: the trail continues after the point of the new window nearest to its end.
 * A poll that doesn't reach back to the trail (a gap, a restart) starts a new segment, so no line is drawn across it.
 */
export function mergeTail(previous: Position[][], latest: Position[]): Position[][] {
  if (latest.length === 0) return previous;
  const current = previous[previous.length - 1];
  if (!current) return [latest];
  const last = current[current.length - 1];
  let nearest = -1;
  let nearestDistance = Infinity;
  latest.forEach((point, i) => {
    const distance = Math.hypot(point[0] - last[0], point[1] - last[1]);
    if (distance <= nearestDistance) {
      nearest = i;
      nearestDistance = distance;
    }
  });
  if (nearestDistance > CONTINUES_WITHIN_DEG) return [...previous, latest];
  const fresh = latest.slice(nearest + 1);
  return fresh.length === 0 ? previous : [...previous.slice(0, -1), [...current, ...fresh]];
}
