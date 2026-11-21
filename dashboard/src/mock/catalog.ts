import type { SessionSource } from "@/types/common";
import type { Mount, People, Vehicle } from "@/types/sessions";

import type { RouteId } from "./world";

export const MockQuality = {
  OK: "ok",
  DEGRADED: "degraded",
  BAD: "bad",
} as const;
export type MockQuality = (typeof MockQuality)[keyof typeof MockQuality];

/** A stretch without mobile signal, repeating every `cycleS`: batches wait on the phone, then arrive in a burst. */
export interface DeadZone {
  startS: number;
  durationS: number;
  cycleS: number;
  /** How much faster than real time the backlog is processed once the signal is back. */
  catchUpFactor: number;
}

export interface SessionSpec {
  sessionId: string;
  deviceId: string;
  routeId: RouteId;
  laps: number;
  vehicle: Vehicle;
  cruiseKmh: number;
  /** Fixed start for recorded sessions; `null` = placed relative to page load (live or `endedBeforeLoadMs`). */
  startedAt: string | null;
  /** For a trip that ended just before the page loaded, so it is still being finalized. */
  endedBeforeLoadMs: number | null;
  /** session.json reached the backend (spec §6.1); without it vehicle and mount are unknown. */
  contextKnown: boolean;
  /** Closed after 15 min without batches because the app's Stop message never came. */
  incomplete: boolean;
  deadZone: DeadZone | null;
  source: SessionSource;
  mount: Mount;
  people: People;
  quality: MockQuality;
  /** Replays re-send the data of this session. */
  replayOf: string | null;
  live: boolean;
}

const RIGID_MOUNT: Mount = {
  location: "taped flat on centre console",
  phoneOrientation: "screen up, top of phone pointing to vehicle front",
  rigid: true,
  handheld: false,
};

const BUS_MOUNT: Mount = {
  location: "clamped to the floor next to the rear door",
  phoneOrientation: "screen up, top of phone pointing to vehicle front",
  rigid: true,
  handheld: false,
};

const HANDHELD_MOUNT: Mount = {
  location: "held in the hand",
  phoneOrientation: "varies",
  rigid: false,
  handheld: true,
};

const people = (raterSeat: string, raterPosture: People["raterPosture"] = "seated", passengerCount = 3): People => ({
  operatorSeat: "front passenger",
  raterSeat,
  raterPosture,
  passengerCount,
});

const LOGAN: Vehicle = { type: "car", makeModel: "Dacia Logan 2019", line: null };
const GOLF: Vehicle = { type: "car", makeModel: "VW Golf 7", line: null };
const BUS_35: Vehicle = { type: "bus", makeModel: "Mercedes Citaro", line: "35" };
const TRAM_101: Vehicle = { type: "tram", makeModel: "Pesa Swing", line: "101" };

const IPHONE_A = "5d7c3a1e-6f0b-4b4a-9a43-0c1f8e2b7d10";
const IPHONE_B = "a2e9b4c7-1d38-4f6e-8b25-7e4c9d0a3f61";

/** Trips are streamed live by default: that is the main path to the cloud (plan 02 §7, D32). */
const base = {
  laps: 1,
  source: "live",
  quality: "ok",
  replayOf: null,
  live: false,
  endedBeforeLoadMs: null,
  contextKnown: true,
  incomplete: false,
  deadZone: null,
} as const satisfies Partial<SessionSpec>;

const UNKNOWN_VEHICLE: Vehicle = { type: "unknown", makeModel: "", line: null };
const UNKNOWN_MOUNT: Mount = { location: "unknown", phoneOrientation: "unknown", rigid: false, handheld: false };

/** Every mock session. Dates are fixed so the dataset is reproducible. */
export const SESSION_SPECS: SessionSpec[] = [
  {
    ...base,
    sessionId: "3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    laps: 2,
    vehicle: LOGAN,
    cruiseKmh: 38,
    startedAt: "2026-11-18T09:10:12.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left"),
  },
  {
    ...base,
    sessionId: "7a4e0c3d-52b8-4f19-8e6a-1b9c3d7e5f22",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    vehicle: LOGAN,
    cruiseKmh: 22,
    startedAt: "2026-11-18T10:05:40.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left"),
  },
  {
    ...base,
    sessionId: "c81d5f2a-9e3b-47c0-a6d4-2f8b1e0c9a33",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    vehicle: LOGAN,
    cruiseKmh: 50,
    startedAt: "2026-11-19T08:40:05.000Z",
    mount: RIGID_MOUNT,
    people: people("rear right"),
  },
  {
    ...base,
    sessionId: "0e6b9a4f-3c27-4d85-b1e9-8c5a2d4f7b44",
    // The app was killed before Stop: closed after 15 min of silence and finalized as incomplete.
    incomplete: true,
    deviceId: IPHONE_B,
    routeId: "cityLoop",
    vehicle: GOLF,
    cruiseKmh: 38,
    startedAt: "2026-11-19T17:20:31.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left", "seated", 2),
  },
  {
    ...base,
    sessionId: "5b2f8e1c-7a49-4c3d-9e06-4d1b7a8c2e55",
    deviceId: IPHONE_A,
    routeId: "fagetHill",
    vehicle: LOGAN,
    cruiseKmh: 50,
    startedAt: "2026-11-19T11:00:00.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left"),
  },
  {
    ...base,
    sessionId: "9d3a6c0b-2e8f-4b71-a5c4-6e2f9b1d3a66",
    deviceId: IPHONE_B,
    routeId: "fagetHill",
    vehicle: GOLF,
    cruiseKmh: 45,
    startedAt: "2026-11-20T09:30:18.000Z",
    mount: RIGID_MOUNT,
    people: people("rear right", "seated", 2),
  },
  {
    ...base,
    sessionId: "e4c7b2a9-6d1f-4e38-8b0a-3c9e5d2f1b77",
    deviceId: IPHONE_A,
    routeId: "bus35",
    vehicle: BUS_35,
    cruiseKmh: 32,
    startedAt: "2026-11-19T13:15:44.000Z",
    mount: BUS_MOUNT,
    people: people("rear, over axle", "seated", 24),
  },
  {
    ...base,
    sessionId: "1a8d4e6c-0b3f-4a92-9d57-5e1c8b4a2f88",
    deviceId: IPHONE_B,
    routeId: "bus35",
    vehicle: BUS_35,
    cruiseKmh: 30,
    startedAt: "2026-11-20T08:10:09.000Z",
    mount: BUS_MOUNT,
    people: people("middle, standing area", "standing", 41),
  },
  {
    ...base,
    sessionId: "6c0e3b8d-4f2a-49e1-b7c6-9a3d1e5b0c99",
    deviceId: IPHONE_A,
    routeId: "bus35",
    vehicle: BUS_35,
    cruiseKmh: 33,
    startedAt: "2026-11-20T12:00:27.000Z",
    mount: BUS_MOUNT,
    people: people("front", "seated", 18),
  },
  {
    ...base,
    sessionId: "b5f1d9c3-8e6a-4d07-a2b4-0f7c3e9d1a10",
    // No mobile signal in the tram that day: the folder was uploaded from a laptop (fallback).
    source: "upload",
    deviceId: IPHONE_B,
    routeId: "tram101",
    vehicle: TRAM_101,
    cruiseKmh: 28,
    startedAt: "2026-11-19T15:30:52.000Z",
    mount: BUS_MOUNT,
    people: people("middle", "seated", 35),
  },
  {
    ...base,
    sessionId: "2d9e7a1b-5c4f-4b8e-9f3a-7b2d6c0e4f21",
    deviceId: IPHONE_A,
    routeId: "tram101",
    vehicle: TRAM_101,
    cruiseKmh: 27,
    startedAt: "2026-11-20T14:10:36.000Z",
    mount: BUS_MOUNT,
    people: people("rear, standing", "standing", 52),
  },
  {
    ...base,
    sessionId: "8f4b0d2e-1a7c-4e5d-b9f8-2c6e0a4d8b32",
    deviceId: IPHONE_B,
    routeId: "cityLoop",
    vehicle: GOLF,
    cruiseKmh: 36,
    startedAt: "2026-11-18T18:02:14.000Z",
    mount: HANDHELD_MOUNT,
    people: people("front passenger", "seated", 2),
  },
  {
    ...base,
    sessionId: "4e2c8a6f-9b1d-4f3e-a0c7-5d8b2e6f9c43",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    vehicle: LOGAN,
    cruiseKmh: 40,
    startedAt: "2026-11-20T16:00:03.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left"),
    quality: "degraded",
  },
  {
    ...base,
    sessionId: "d0a5e3c1-7f9b-4c2a-8e6d-1b4f7a9c3e54",
    source: "upload",
    deviceId: IPHONE_B,
    routeId: "cityLoop",
    vehicle: GOLF,
    cruiseKmh: 38,
    startedAt: "2026-11-17T20:45:00.000Z",
    mount: RIGID_MOUNT,
    people: people("rear left", "seated", 2),
    quality: "bad",
  },
  {
    ...base,
    sessionId: "f7b3c9e5-2a0d-4e6f-9c18-3e5a7d1b9f65",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    laps: 2,
    vehicle: LOGAN,
    cruiseKmh: 38,
    startedAt: "2026-11-20T17:30:00.000Z",
    source: "replay",
    mount: RIGID_MOUNT,
    people: people("rear left"),
    replayOf: "3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11",
  },
  {
    ...base,
    sessionId: "aa61f0d4-3b8e-4c5a-9d27-6f1e4b8c0d76",
    deviceId: IPHONE_A,
    routeId: "cityLoop",
    laps: 6,
    vehicle: LOGAN,
    cruiseKmh: 36,
    startedAt: null,
    mount: RIGID_MOUNT,
    people: people("rear left"),
    live: true,
    // The loop crosses a spot without signal: the live view goes stale, then catches up.
    deadZone: { startS: 9 * 60, durationS: 45, cycleS: 12 * 60, catchUpFactor: 5 },
  },
  {
    ...base,
    sessionId: "c3e9a7b1-6d2f-4f80-b4e5-9a1c7e3d5b87",
    deviceId: "replay-tool",
    routeId: "bus35",
    // A replay re-sends exactly the original trip (one pass over an open route, which must not wrap).
    laps: 1,
    vehicle: BUS_35,
    cruiseKmh: 32,
    startedAt: null,
    source: "replay",
    mount: BUS_MOUNT,
    people: people("rear, over axle", "seated", 24),
    replayOf: "e4c7b2a9-6d1f-4e38-8b0a-3c9e5d2f1b77",
    live: true,
  },
  {
    ...base,
    // Ended one minute before the page loaded: still being finalized, then joins the map.
    sessionId: "5e8c1a7d-2b9f-4c63-a0d4-8f1e3b6c9a21",
    deviceId: IPHONE_B,
    routeId: "cityLoop",
    vehicle: GOLF,
    cruiseKmh: 34,
    startedAt: null,
    endedBeforeLoadMs: 60_000,
    mount: RIGID_MOUNT,
    people: people("rear right", "seated", 2),
  },
  {
    ...base,
    // Streamed, but session.json never arrived (older app build): context unknown, kept off the map.
    sessionId: "91d4b7e2-6a3c-4f58-9b0e-2c7a5d8f1e43",
    deviceId: IPHONE_B,
    routeId: "cityLoop",
    vehicle: UNKNOWN_VEHICLE,
    cruiseKmh: 35,
    startedAt: "2026-11-17T16:20:00.000Z",
    mount: UNKNOWN_MOUNT,
    people: { operatorSeat: "unknown", raterSeat: "unknown", raterPosture: "seated", passengerCount: 0 },
    contextKnown: false,
    incomplete: true,
  },
];
