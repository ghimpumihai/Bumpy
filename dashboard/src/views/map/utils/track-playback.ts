import type { Position } from "@/types/common";
import type { SessionTrack } from "@/types/sessions";
import { lowerIndex } from "@/utils/geo";

import { REPLAY_GAP_DEG, REPLAY_GAP_MS } from "./constants";

export interface TrackPlayback {
  points: Position[];
  /** Recorded epoch ms per point. */
  times: number[];
  /** Playback ms per point, from 0, with long silences shortened. */
  clock: number[];
  /** The point starts a new line: the GPS went quiet or jumped before it. */
  cut: boolean[];
}

export interface PlaybackFrame {
  lines: Position[][];
  head: Position;
  /** Recorded time of the head, epoch ms. */
  time: number;
}

export function trackPlayback(track: SessionTrack): TrackPlayback {
  const points = track.geometry.coordinates as Position[];
  const times = track.properties.times;
  const clock: number[] = [];
  const cut: boolean[] = [];
  points.forEach((point, i) => {
    if (i === 0) {
      clock.push(0);
      cut.push(true);
      return;
    }
    const step = times[i] - times[i - 1];
    const jump = Math.abs(point[0] - points[i - 1][0]) + Math.abs(point[1] - points[i - 1][1]);
    clock.push(clock[i - 1] + Math.min(step, REPLAY_GAP_MS));
    cut.push(step > REPLAY_GAP_MS || jump > REPLAY_GAP_DEG);
  });
  return { points, times, clock, cut };
}

export const playbackLength = ({ clock }: TrackPlayback) => clock[clock.length - 1];

/** The track driven up to `elapsed` playback ms, ending at the interpolated position. */
export function playbackFrame({ points, times, clock, cut }: TrackPlayback, elapsed: number): PlaybackFrame {
  const last = lowerIndex(clock, elapsed);
  const lines: Position[][] = [];
  for (let i = 0; i <= last; i++) {
    if (cut[i]) lines.push([]);
    lines[lines.length - 1].push(points[i]);
  }
  let head = points[last];
  let time = times[last];
  const next = last + 1;
  if (next < points.length && !cut[next] && clock[next] > clock[last]) {
    const f = Math.min(1, Math.max(0, (elapsed - clock[last]) / (clock[next] - clock[last])));
    head = [head[0] + (points[next][0] - head[0]) * f, head[1] + (points[next][1] - head[1]) * f];
    time += (times[next] - time) * f;
    lines[lines.length - 1].push(head);
  }
  return { lines: lines.filter((line) => line.length > 1), head, time };
}
