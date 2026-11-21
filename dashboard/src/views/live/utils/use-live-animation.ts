import { useEffect, useRef, useState } from "react";

import { LIVE_POLL_INTERVAL_MS } from "@/constants";
import type { Position } from "@/types/common";

import { LIVE_FRAME_MS, LIVE_PULSE_PERIOD_MS } from "./constants";

interface Cursor {
  /** The segment of the trail the marker is on. */
  segment: number;
  /** Distance along that segment (degrees) at the start of the glide, and where it ends up. */
  from: number;
  to: number;
  startedAt: number;
}

export interface LiveAnimation {
  /** The trail up to the marker, never ahead of it. */
  trails: Record<string, Position[][]>;
  /** Where each marker is drawn right now (absent while a trip has no trail yet). */
  heads: Record<string, Position>;
  /** 0 → 1 once per pulse period; drives the halo around the markers. */
  pulse: number;
  /** The time of this frame (same clock as `performance.now()`), for animations that run once. */
  now: number;
}

const EMPTY: LiveAnimation = { trails: {}, heads: {}, pulse: 0, now: 0 };

const length = (line: Position[]) => line.slice(1).reduce((sum, p, i) => sum + Math.hypot(p[0] - line[i][0], p[1] - line[i][1]), 0);

/** The part of the line within `distance` of its start, ending exactly at that distance. */
function cut(line: Position[], distance: number): Position[] {
  const out: Position[] = [line[0]];
  let left = distance;
  for (let i = 1; i < line.length; i++) {
    const leg = Math.hypot(line[i][0] - line[i - 1][0], line[i][1] - line[i - 1][1]);
    if (left >= leg) {
      out.push(line[i]);
      left -= leg;
    } else {
      const f = leg === 0 ? 0 : left / leg;
      out.push([line[i - 1][0] + (line[i][0] - line[i - 1][0]) * f, line[i - 1][1] + (line[i][1] - line[i - 1][1]) * f]);
      break;
    }
  }
  return out;
}

/**
 * Polls arrive every couple of seconds; the marker follows the trail at a steady pace to its newest point over one poll
 * interval instead of jumping, and the trail is drawn only up to the marker. The halo pulses. Frames are throttled
 * because the map re-renders on every one.
 */
export function useLiveAnimation(tails: Record<string, Position[][]>): LiveAnimation {
  const latest = useRef(tails);
  const cursors = useRef<Record<string, Cursor>>({});
  const [animation, setAnimation] = useState<LiveAnimation>(EMPTY);

  useEffect(() => {
    latest.current = tails;
    const now = performance.now();
    for (const [id, segments] of Object.entries(tails)) {
      const segment = segments.length - 1;
      if (segment < 0) continue;
      const end = length(segments[segment]);
      const cursor = cursors.current[id];
      if (!cursor) {
        cursors.current[id] = { segment, from: end, to: end, startedAt: now };
        continue;
      }
      const t = Math.min(1, (now - cursor.startedAt) / LIVE_POLL_INTERVAL_MS);
      const here = cursor.from + (cursor.to - cursor.from) * t;
      cursors.current[id] = { segment, from: cursor.segment === segment ? here : 0, to: end, startedAt: now };
    }
  }, [tails]);

  useEffect(() => {
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let frame = 0;
    let last = 0;
    const tick = (now: number) => {
      frame = requestAnimationFrame(tick);
      if (now - last < LIVE_FRAME_MS) return;
      last = now;
      const trails: Record<string, Position[][]> = {};
      const heads: Record<string, Position> = {};
      for (const [id, segments] of Object.entries(latest.current)) {
        const cursor = cursors.current[id];
        if (!cursor || !segments[cursor.segment]) continue;
        const t = Math.min(1, (now - cursor.startedAt) / LIVE_POLL_INTERVAL_MS);
        const drawn = cut(segments[cursor.segment], cursor.from + (cursor.to - cursor.from) * t);
        trails[id] = [...segments.slice(0, cursor.segment), drawn];
        heads[id] = drawn[drawn.length - 1];
      }
      setAnimation({ trails, heads, pulse: still ? 0 : (now % LIVE_PULSE_PERIOD_MS) / LIVE_PULSE_PERIOD_MS, now });
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, []);

  return animation;
}
