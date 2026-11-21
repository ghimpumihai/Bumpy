import { describe, expect, it } from "vitest";

import type { Position } from "@/types/common";
import { LIVE_FOLLOW_MAX_STEP_MS, LIVE_FOLLOW_SMOOTHING_MS } from "@/views/live/utils/constants";
import { followCenter, isPanKey } from "@/views/live/utils/follow";

const CENTER: Position = [23.59, 46.76];
const AHEAD: Position = [23.6, 46.77];
const FRAME_MS = 33;

describe("followCenter", () => {
  it("moves part of the way to the vehicle, never past it", () => {
    const [lon, lat] = followCenter(CENTER, AHEAD, FRAME_MS, 40);
    const fraction = 1 - Math.exp(-FRAME_MS / LIVE_FOLLOW_SMOOTHING_MS);
    expect(lon).toBeCloseTo(CENTER[0] + (AHEAD[0] - CENTER[0]) * fraction, 12);
    expect(lat).toBeCloseTo(CENTER[1] + (AHEAD[1] - CENTER[1]) * fraction, 12);
    expect(lon).toBeLessThan(AHEAD[0]);
  });

  it("sits exactly on the vehicle once the gap is under a pixel", () => {
    expect(followCenter(CENTER, AHEAD, FRAME_MS, 0.4)).toEqual(AHEAD);
  });

  it("paces by time, not by frame count", () => {
    // Two 33 ms frames end up where one 66 ms frame does.
    const twice = followCenter(followCenter(CENTER, AHEAD, FRAME_MS, 40), AHEAD, FRAME_MS, 40);
    const once = followCenter(CENTER, AHEAD, 2 * FRAME_MS, 40);
    expect(twice[0]).toBeCloseTo(once[0], 12);
    expect(twice[1]).toBeCloseTo(once[1], 12);
  });

  it("never leaps after a long pause, and stands still for no elapsed time", () => {
    expect(followCenter(CENTER, AHEAD, 60_000, 40)).toEqual(followCenter(CENTER, AHEAD, LIVE_FOLLOW_MAX_STEP_MS, 40));
    expect(followCenter(CENTER, AHEAD, 0, 40)).toEqual(CENTER);
    expect(followCenter(CENTER, AHEAD, -5, 40)).toEqual(CENTER);
  });

  it("keeps up with a moving vehicle: the lag settles at speed × smoothing time", () => {
    // 14 m/s ≈ 50 km/h; work in metres along one axis.
    const speed = 14 / 1000; // m per ms
    let car = 0;
    let camera: Position = [0, 0];
    for (let t = 0; t < 5000; t += FRAME_MS) {
      car += speed * FRAME_MS;
      camera = followCenter(camera, [car, 0], FRAME_MS, Infinity);
    }
    const lagM = car - camera[0];
    expect(lagM).toBeGreaterThan(0);
    expect(lagM).toBeLessThan(speed * LIVE_FOLLOW_SMOOTHING_MS * 1.1);
  });
});

describe("isPanKey", () => {
  it("is true for plain arrow keys only", () => {
    expect(isPanKey(new KeyboardEvent("keydown", { key: "ArrowLeft" }))).toBe(true);
    expect(isPanKey(new KeyboardEvent("keydown", { key: "ArrowUp", shiftKey: true }))).toBe(false);
    expect(isPanKey(new KeyboardEvent("keydown", { key: "+" }))).toBe(false);
    expect(isPanKey(new MouseEvent("click"))).toBe(false);
    expect(isPanKey(undefined)).toBe(false);
  });
});
