import { MS_PER_SECOND, MS_TO_KMH } from "@/constants/units";
import type { RoadEventType, VehicleType } from "@/types/common";
import type { DetectionMetrics, DetectionScore, SessionLabel, SicknessRating } from "@/types/sessions";
import type { Position } from "@/types/common";

import type { SessionSpec } from "./catalog";
import { createRandom, hashString, type Random } from "./random";
import { getWorld, ROUTE_STEP_M, STOPS, type Route, type RouteSample } from "./world";

/** The read API's session_series is about 5 Hz (plan 02 §8). */
export const SERIES_HZ = 5;
const DT_S = 1 / SERIES_HZ;
/** Potholes are only counted above 15 km/h (plan 02 §9). */
export const POTHOLE_MIN_SPEED_MS = 15 / MS_TO_KMH;
/** Detections are matched to manual taps within ±1.5 s (plan 02 §9). */
export const TAP_MATCH_WINDOW_S = 1.5;
const SICKNESS_PROMPT_INTERVAL_S = 120;
const REFERENCE_SPEED_MS = 10;
/** True speed exponent of roughness used to generate data; the aggregation should recover ≈ this. */
export const TRUE_SPEED_EXPONENT = 0.6;
const INITIAL_IDLE_S = 40;
const MIN_ROLLING_SPEED_MS = 0.3;
const MOVING_SPEED_MS = 1;
const IDLE_VERTICAL_RMS = 0.08;

interface VehicleDynamics {
  accel: number;
  decel: number;
  maxLateral: number;
  roughnessFactor: number;
  awFactor: number;
  stopDwellS: [number, number];
}

const DYNAMICS: Record<VehicleType, VehicleDynamics> = {
  car: { accel: 1.6, decel: 2.2, maxLateral: 2.2, roughnessFactor: 1, awFactor: 1, stopDwellS: [0, 28] },
  bus: { accel: 1.0, decel: 1.3, maxLateral: 1.3, roughnessFactor: 1.35, awFactor: 1.45, stopDwellS: [12, 30] },
  tram: { accel: 0.9, decel: 1.2, maxLateral: 1.1, roughnessFactor: 1.18, awFactor: 0.75, stopDwellS: [15, 30] },
  bike: { accel: 0.8, decel: 1.5, maxLateral: 2, roughnessFactor: 1.6, awFactor: 1.2, stopDwellS: [0, 20] },
  boat: { accel: 0.5, decel: 0.5, maxLateral: 1, roughnessFactor: 0.4, awFactor: 2, stopDwellS: [0, 0] },
  unknown: { accel: 1.5, decel: 2, maxLateral: 2, roughnessFactor: 1, awFactor: 1, stopDwellS: [0, 20] },
};

const SPEED_BUMP_SPEED_MS = 15 / MS_TO_KMH;
const COBBLESTONE_SPEED_MS = 30 / MS_TO_KMH;
const SPEED_BUMP_MAX_DETECT_MS = 40 / MS_TO_KMH;
const RAIL_JOINT_SPACING_M = 25;
const RAIL_JOINT_DETECT_PROBABILITY = 0.12;
const FALSE_POSITIVES_PER_KM = 0.25;

export interface SimulatedEvent {
  id: string;
  type: RoadEventType;
  sampleIndex: number;
  tMs: number;
  position: Position;
  speedMs: number;
  magnitude: number;
  confidence: number;
  matchedLabel: boolean;
}

export interface SimulatedObservation {
  cell: string;
  passIndex: number;
  firstSample: number;
  tStartMs: number;
  durationS: number;
  meanSpeedMs: number;
  roughnessRms: number | null;
  awRms: number;
  potholeCount: number;
}

interface Tap {
  type: RoadEventType;
  sampleIndex: number;
}

export interface SimulatedSession {
  spec: SessionSpec;
  route: Route;
  startMs: number;
  t: Float64Array;
  s: Float64Array;
  lon: Float64Array;
  lat: Float64Array;
  speed: Float64Array;
  aVert: Float64Array;
  aLat: Float64Array;
  aLon: Float64Array;
  msdv: Float64Array;
  events: SimulatedEvent[];
  labels: (SessionLabel & { sampleIndex: number })[];
  ratings: (SicknessRating & { sampleIndex: number })[];
  observations: SimulatedObservation[];
  taps: Tap[];
  totalDistanceM: number;
}

interface Breakpoint {
  t: number;
  s: number;
  v: number;
}

/** Speed limits over one lap, then forward/backward acceleration limits (a standard velocity profile). */
function speedProfile(route: Route, spec: SessionSpec, random: Random): Breakpoint[] {
  const dyn = DYNAMICS[spec.vehicle.type];
  const lapSamples = route.samples.length;
  const total = lapSamples * spec.laps;
  const cruise = spec.cruiseKmh / MS_TO_KMH;
  const target = new Float64Array(total);
  const dwell = new Float64Array(total);
  const stopIndexes = new Set(STOPS[route.id].map((s) => Math.round(s / ROUTE_STEP_M)));
  const isTransit = spec.vehicle.type === "bus" || spec.vehicle.type === "tram";

  for (let i = 0; i < total; i++) {
    const sample = route.samples[i % lapSamples];
    let v = cruise;
    if (Math.abs(sample.curvature) > 1e-4) v = Math.min(v, Math.sqrt(dyn.maxLateral / Math.abs(sample.curvature)));
    if (sample.features.some((f) => f.type === "speed_bump")) v = Math.min(v, SPEED_BUMP_SPEED_MS);
    if (sample.cobblestones) v = Math.min(v, COBBLESTONE_SPEED_MS);
    // Transit always stops; cars only stop at a red light.
    if (stopIndexes.has(i % lapSamples) && (isTransit || random.chance(0.5))) {
      v = 0;
      dwell[i] = random.range(dyn.stopDwellS[0], dyn.stopDwellS[1]);
    }
    target[i] = v;
  }
  target[0] = 0;
  dwell[0] = INITIAL_IDLE_S;
  target[total - 1] = 0;

  const v = Float64Array.from(target);
  for (let i = 1; i < total; i++) v[i] = Math.min(v[i], Math.sqrt(v[i - 1] ** 2 + 2 * dyn.accel * ROUTE_STEP_M));
  for (let i = total - 2; i >= 0; i--) v[i] = Math.min(v[i], Math.sqrt(v[i + 1] ** 2 + 2 * dyn.decel * ROUTE_STEP_M));

  const points: Breakpoint[] = [];
  let t = 0;
  for (let i = 0; i < total; i++) {
    if (i > 0) t += ROUTE_STEP_M / Math.max((v[i - 1] + v[i]) / 2, MIN_ROLLING_SPEED_MS);
    points.push({ t, s: i * ROUTE_STEP_M, v: v[i] });
    if (dwell[i] > 0) {
      t += dwell[i];
      points.push({ t, s: i * ROUTE_STEP_M, v: v[i] });
    }
  }
  return points;
}

function roughnessRms(truth: number, speedMs: number, dyn: VehicleDynamics, spec: SessionSpec): number {
  if (speedMs < MOVING_SPEED_MS) return IDLE_VERTICAL_RMS;
  const handheld = spec.mount.handheld ? 0.55 : 1;
  return truth * dyn.roughnessFactor * handheld * (speedMs / REFERENCE_SPEED_MS) ** TRUE_SPEED_EXPONENT;
}

function scoreDetections(events: SimulatedEvent[], taps: Tap[], type: RoadEventType): DetectionScore {
  const window = TAP_MATCH_WINDOW_S * SERIES_HZ;
  const detections = events.filter((e) => e.type === type);
  const typedTaps = taps.filter((tap) => tap.type === type);
  const near = (a: number, b: number) => Math.abs(a - b) <= window;
  const truePositives = detections.filter((e) => typedTaps.some((tap) => near(tap.sampleIndex, e.sampleIndex))).length;
  const falsePositives = detections.length - truePositives;
  const falseNegatives = typedTaps.filter((tap) => !detections.some((e) => near(tap.sampleIndex, e.sampleIndex))).length;
  const ratio = (num: number, den: number) => (den > 0 ? num / den : null);
  return {
    truePositives,
    falsePositives,
    falseNegatives,
    precision: ratio(truePositives, truePositives + falsePositives),
    recall: ratio(truePositives, truePositives + falseNegatives),
  };
}

export function detectionMetrics(sim: SimulatedSession, lastSample: number): DetectionMetrics {
  const events = sim.events.filter((e) => e.sampleIndex <= lastSample);
  const taps = sim.taps.filter((tap) => tap.sampleIndex <= lastSample);
  return {
    pothole: scoreDetections(events, taps, "pothole"),
    speed_bump: scoreDetections(events, taps, "speed_bump"),
  };
}

export function simulateSession(spec: SessionSpec, startMs: number): SimulatedSession {
  const world = getWorld();
  const route = world.routes[spec.routeId];
  // Replays carry exactly the data of the original trip.
  const random = createRandom(hashString(spec.replayOf ?? spec.sessionId));
  const dyn = DYNAMICS[spec.vehicle.type];
  const profile = speedProfile(route, spec, random);
  const durationS = profile[profile.length - 1].t;
  const n = Math.floor(durationS * SERIES_HZ) + 1;
  const lapSamples = route.samples.length;
  const totalDistanceM = profile[profile.length - 1].s;

  const sim: SimulatedSession = {
    spec,
    route,
    startMs,
    t: new Float64Array(n),
    s: new Float64Array(n),
    lon: new Float64Array(n),
    lat: new Float64Array(n),
    speed: new Float64Array(n),
    aVert: new Float64Array(n),
    aLat: new Float64Array(n),
    aLon: new Float64Array(n),
    msdv: new Float64Array(n),
    events: [],
    labels: [],
    ratings: [],
    observations: [],
    taps: [],
    totalDistanceM,
  };

  const sampleAt = (s: number): RouteSample => route.samples[Math.round(s / ROUTE_STEP_M) % lapSamples];
  const roughRms = new Float64Array(n);
  const awInstant = new Float64Array(n);

  let p = 0;
  let msdvSquared = 0;
  for (let k = 0; k < n; k++) {
    const t = k * DT_S;
    while (p < profile.length - 2 && profile[p + 1].t <= t) p++;
    const a = profile[p];
    const b = profile[p + 1];
    const f = b.t > a.t ? Math.min(1, (t - a.t) / (b.t - a.t)) : 0;
    const s = a.s + (b.s - a.s) * f;
    const v = a.s === b.s ? 0 : a.v + (b.v - a.v) * f;
    // Cell and features come from the nearest grid point; the position is interpolated between the
    // grid points on either side.
    const sample = sampleAt(s);
    const baseIndex = Math.floor(s / ROUTE_STEP_M) % lapSamples;
    const base = route.samples[baseIndex];
    const next = route.samples[Math.min(lapSamples - 1, baseIndex + 1)];
    const within = (s % ROUTE_STEP_M) / ROUTE_STEP_M;
    const truth = world.cells.get(sample.cell);

    sim.t[k] = startMs + t * MS_PER_SECOND;
    sim.s[k] = s;
    sim.lon[k] = base.position[0] + (next.position[0] - base.position[0]) * within;
    sim.lat[k] = base.position[1] + (next.position[1] - base.position[1]) * within;
    sim.speed[k] = Math.max(0, v + random.gaussian() * 0.08 * Math.min(1, v));
    roughRms[k] = roughnessRms(truth?.roughness ?? 0.4, v, dyn, spec);
    sim.aVert[k] = random.gaussian() * roughRms[k];
    sim.aLat[k] = v * v * sample.curvature + random.gaussian() * 0.12;
    const aw = (truth?.awRms ?? 0.05) * dyn.awFactor * (v < MOVING_SPEED_MS ? 0.35 : 1);
    awInstant[k] = aw;
    msdvSquared += aw * aw * DT_S;
    sim.msdv[k] = Math.sqrt(msdvSquared);
  }
  for (let k = 0; k < n; k++) {
    const prev = sim.speed[Math.max(0, k - 2)];
    const next = sim.speed[Math.min(n - 1, k + 2)];
    sim.aLon[k] = (next - prev) / (4 * DT_S) + random.gaussian() * 0.08;
  }

  addEventsAndTaps(sim, random, dyn);
  addLabelsAndRatings(sim, random);
  sim.observations = buildObservations(sim, roughRms, awInstant, random);
  return sim;
}

function addEventsAndTaps(sim: SimulatedSession, random: Random, dyn: VehicleDynamics) {
  const { spec, route } = sim;
  const lapSamples = route.samples.length;
  const handheld = spec.mount.handheld;
  const lastHit = new Map<string, number>();
  const tapDelay = () => Math.round(random.range(0.5, 1.4) * SERIES_HZ);
  let eventSeq = 0;
  const pushEvent = (k: number, type: RoadEventType, magnitude: number, confidence: number) => {
    sim.events.push({
      id: `${spec.sessionId.slice(0, 8)}-${eventSeq++}`,
      type,
      sampleIndex: k,
      tMs: sim.t[k],
      position: [sim.lon[k], sim.lat[k]],
      speedMs: sim.speed[k],
      magnitude,
      confidence,
      matchedLabel: false,
    });
  };

  let previousGrid = -1;
  for (let k = 0; k < sim.t.length; k++) {
    const grid = Math.round(sim.s[k] / ROUTE_STEP_M);
    if (grid === previousGrid) continue;
    const v = sim.speed[k];
    for (let g = previousGrid + 1; g <= grid; g++) {
      const sample = route.samples[g % lapSamples];
      for (const feature of sample.features) {
        const last = lastHit.get(feature.id);
        if (last !== undefined && k - last < 10 * SERIES_HZ) continue;
        lastHit.set(feature.id, k);
        if (feature.type === "pothole") {
          const magnitude = random.range(6, 12) * dyn.roughnessFactor;
          sim.aVert[k] += magnitude * (random.chance(0.5) ? 1 : -1);
          if (v > POTHOLE_MIN_SPEED_MS && random.chance(handheld ? 0.45 : 0.86)) {
            pushEvent(k, "pothole", magnitude, random.range(0.65, 0.98));
          }
          if (random.chance(v > POTHOLE_MIN_SPEED_MS ? 0.8 : 0.4)) sim.taps.push({ type: "pothole", sampleIndex: k + tapDelay() });
        } else {
          const pitchRate = random.range(0.2, 0.5);
          if (v < SPEED_BUMP_MAX_DETECT_MS && random.chance(0.82)) pushEvent(k, "speed_bump", pitchRate, random.range(0.6, 0.95));
          if (random.chance(0.85)) sim.taps.push({ type: "speed_bump", sampleIndex: k + tapDelay() });
        }
      }
      if (spec.vehicle.type === "tram" && (g * ROUTE_STEP_M) % RAIL_JOINT_SPACING_M === 0 && v > MOVING_SPEED_MS) {
        if (random.chance(RAIL_JOINT_DETECT_PROBABILITY)) pushEvent(k, "rail_joint", random.range(3, 6), random.range(0.5, 0.8));
      }
    }
    const metres = (grid - Math.max(previousGrid, 0)) * ROUTE_STEP_M;
    if (v > POTHOLE_MIN_SPEED_MS && random.chance((FALSE_POSITIVES_PER_KM * metres) / 1000)) {
      pushEvent(k, "pothole", random.range(3.5, 5.5), random.range(0.3, 0.55));
    }
    previousGrid = grid;
  }

  const last = sim.t.length - 1;
  sim.taps = sim.taps.filter((tap) => tap.sampleIndex <= last);
  const window = TAP_MATCH_WINDOW_S * SERIES_HZ;
  for (const event of sim.events) {
    event.matchedLabel = sim.taps.some((tap) => tap.type === event.type && Math.abs(tap.sampleIndex - event.sampleIndex) <= window);
  }
}

function addLabelsAndRatings(sim: SimulatedSession, random: Random) {
  const { spec, route } = sim;
  const n = sim.t.length;
  const lapSamples = route.samples.length;
  const label = (k: number, type: string, value: string | null = null, note: string | null = null) => {
    if (k < 0 || k >= n) return;
    sim.labels.push({ sampleIndex: k, tUtc: new Date(sim.t[k]).toISOString(), type, value, note });
  };

  label(4 * SERIES_HZ, "sync_tap");
  label(10 * SERIES_HZ, "segment_start", "idle");
  label((INITIAL_IDLE_S - 2) * SERIES_HZ, "segment_end", "idle");
  label(n - 8 * SERIES_HZ, "sync_tap");
  for (const tap of sim.taps) label(tap.sampleIndex, tap.type);

  let onCobbles = false;
  let onHill = false;
  for (let k = 0; k < n; k++) {
    const sample = route.samples[Math.round(sim.s[k] / ROUTE_STEP_M) % lapSamples];
    if (sample.cobblestones !== onCobbles) {
      onCobbles = sample.cobblestones;
      label(k, onCobbles ? "surface_start" : "surface_end", "cobblestones");
    }
    if (sample.hillSection !== onHill) {
      onHill = sample.hillSection;
      label(k, onHill ? "segment_start" : "segment_end", "winding");
    }
  }
  if (onCobbles) label(n - 1, "surface_end", "cobblestones", "auto at stop");
  if (onHill) label(n - 1, "segment_end", "winding", "auto at stop");

  if (spec.quality === "degraded") {
    label(Math.round(n * 0.35), "phone_moved");
    label(Math.round(n * 0.7), "phone_moved");
  }

  const standingBonus = spec.people.raterPosture === "standing" ? 1 : 0;
  for (let k = SICKNESS_PROMPT_INTERVAL_S * SERIES_HZ; k < n; k += SICKNESS_PROMPT_INTERVAL_S * SERIES_HZ) {
    label(k, "sickness_prompt");
    if (random.chance(0.08)) {
      label(k + 30 * SERIES_HZ, "sickness_missed");
      continue;
    }
    const answer = k + Math.round(random.range(3, 12) * SERIES_HZ);
    if (answer >= n) continue;
    const misc = Math.round(Math.min(10, Math.max(0, sim.msdv[answer] * 0.55 + standingBonus + random.gaussian() * 0.6)));
    label(answer, "sickness", String(misc), "prompt");
    sim.ratings.push({
      sampleIndex: answer,
      tUtc: new Date(sim.t[answer]).toISOString(),
      value: misc,
      msdvSoFar: sim.msdv[answer],
    });
  }
  sim.labels.sort((a, b) => a.sampleIndex - b.sampleIndex);
}

function buildObservations(
  sim: SimulatedSession,
  roughRms: Float64Array,
  awInstant: Float64Array,
  random: Random,
): SimulatedObservation[] {
  const { route, spec } = sim;
  const lapSamples = route.samples.length;
  const observations: SimulatedObservation[] = [];
  const noise = spec.mount.handheld ? 0.35 : 0.1;
  const potholeSamples = new Set(sim.events.filter((e) => e.type === "pothole").map((e) => e.sampleIndex));

  let start = 0;
  const flush = (end: number) => {
    const cell = route.samples[Math.round(sim.s[start] / ROUTE_STEP_M) % lapSamples].cell;
    let speedSum = 0;
    let roughSum = 0;
    let movingSpeedSum = 0;
    let moving = 0;
    let awSum = 0;
    let potholes = 0;
    for (let k = start; k < end; k++) {
      speedSum += sim.speed[k];
      awSum += awInstant[k] ** 2;
      if (potholeSamples.has(k)) potholes++;
      if (sim.speed[k] >= MOVING_SPEED_MS) {
        roughSum += roughRms[k] ** 2;
        movingSpeedSum += sim.speed[k];
        moving++;
      }
    }
    const count = end - start;
    observations.push({
      cell,
      passIndex: observations.length,
      firstSample: start,
      tStartMs: sim.t[start],
      durationS: count / SERIES_HZ,
      // Speed over the same (moving) samples as the roughness RMS; mixing in stops biases β low.
      meanSpeedMs: moving >= 3 ? movingSpeedSum / moving : speedSum / count,
      roughnessRms: moving >= 3 ? Math.sqrt(roughSum / moving) * Math.exp(random.gaussian() * noise) : null,
      awRms: Math.sqrt(awSum / count) * Math.exp(random.gaussian() * noise),
      potholeCount: potholes,
    });
    start = end;
  };

  let currentCell = route.samples[0].cell;
  for (let k = 1; k < sim.t.length; k++) {
    const cell = route.samples[Math.round(sim.s[k] / ROUTE_STEP_M) % lapSamples].cell;
    if (cell !== currentCell) {
      flush(k);
      currentCell = cell;
    }
  }
  flush(sim.t.length);
  return observations;
}
