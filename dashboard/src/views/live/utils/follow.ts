import type { Position } from "@/types/common";

import { LIVE_FOLLOW_MAX_STEP_MS, LIVE_FOLLOW_SMOOTHING_MS, LIVE_FOLLOW_SNAP_PX } from "./constants";

/**
 * The camera centre for this frame while the map follows a vehicle: part of the way to it (exponential smoothing, so
 * the pace doesn't depend on the frame rate), or exactly on it once the gap on screen is under a pixel.
 */
export function followCenter(center: Position, target: Position, elapsedMs: number, gapPx: number): Position {
  if (gapPx <= LIVE_FOLLOW_SNAP_PX) return target;
  const step = Math.min(Math.max(elapsedMs, 0), LIVE_FOLLOW_MAX_STEP_MS);
  const fraction = 1 - Math.exp(-step / LIVE_FOLLOW_SMOOTHING_MS);
  return [center[0] + (target[0] - center[0]) * fraction, center[1] + (target[1] - center[1]) * fraction];
}

/** Arrow keys pan the map (Shift + arrows rotate it, which `rotatestart` already reports). */
export const isPanKey = (event: unknown) => event instanceof KeyboardEvent && event.key.startsWith("Arrow") && !event.shiftKey;
