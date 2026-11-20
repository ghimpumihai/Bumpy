import { MS_PER_SECOND, SECONDS_PER_MINUTE } from "@/constants/units";
import type { RoadEventType } from "@/types/common";
import type { ExclusionReason, QualityRow, SessionDetail, SessionQuality, SessionSummary, StreamQuality } from "@/types/sessions";

import { aggregate, type AggregationResult } from "./aggregate";
import { SESSION_SPECS, type SessionSpec } from "./catalog";
import { unitHash } from "./random";
import { detectionMetrics, SERIES_HZ, simulateSession, type SimulatedSession } from "./simulate";

const PROCESSOR_VERSION = "mock-1";
/** Live sessions started this long before the page loaded, so the live view has a track straight away. */
const LIVE_HEAD_START_MS: Record<string, number> = {
  "aa61f0d4-3b8e-4c5a-9d27-6f1e4b8c0d76": 7 * SECONDS_PER_MINUTE * MS_PER_SECOND,
  "c3e9a7b1-6d2f-4f80-b4e5-9a1c7e3d5b87": 3 * SECONDS_PER_MINUTE * MS_PER_SECOND,
};
/** Processing finishes a few minutes after an upload. */
const PROCESSING_DELAY_MS = 4 * SECONDS_PER_MINUTE * MS_PER_SECOND;

export interface MockDataset {
  sims: Map<string, SimulatedSession>;
  aggregation: AggregationResult;
}

let cached: MockDataset | null = null;

export function getDataset(): MockDataset {
  if (cached) return cached;
  const loadMs = Date.now();
  const sims = new Map<string, SimulatedSession>();
  for (const spec of SESSION_SPECS) {
    const startMs = spec.startedAt ? Date.parse(spec.startedAt) : loadMs - (LIVE_HEAD_START_MS[spec.sessionId] ?? 0);
    sims.set(spec.sessionId, simulateSession(spec, startMs));
  }
  const completed = [...sims.values()].filter((sim) => !sim.spec.live);
  const lastUpload = Math.max(...completed.map((sim) => sim.t[sim.t.length - 1]));
  const aggregation = aggregate(
    completed
      .filter((sim) => isIncluded(sim.spec))
      .map((sim) => ({
        sim,
        roughnessEligible: isRoughnessEligible(sim.spec),
        sicknessEligible: !isSicknessExperimental(sim.spec),
      })),
    new Date(lastUpload + PROCESSING_DELAY_MS).toISOString(),
  );
  cached = { sims, aggregation };
  return cached;
}

const isRoughnessEligible = (spec: SessionSpec) => spec.mount.rigid && !spec.mount.handheld;
const isSicknessExperimental = (spec: SessionSpec) => !spec.mount.rigid || spec.mount.handheld;

/** Replays and live-only sessions are never aggregated; bad sessions are kept out automatically (plan 02 §10). */
function exclusionReasons(spec: SessionSpec): ExclusionReason[] {
  const reasons: ExclusionReason[] = [];
  if (spec.source === "replay") reasons.push("replay");
  if (spec.source === "live") reasons.push("live_only");
  if (spec.quality === "bad") reasons.push("bad_quality");
  if (!spec.mount.rigid) reasons.push("not_rigid");
  if (spec.mount.handheld) reasons.push("handheld");
  return reasons;
}

function isIncluded(spec: SessionSpec): boolean {
  return spec.source === "upload" && spec.quality !== "bad";
}

/** Index of the newest sample that exists "now" (live sessions grow in real time). */
export function lastSampleIndex(sim: SimulatedSession, nowMs: number = Date.now()): number {
  const total = sim.t.length - 1;
  if (!sim.spec.live) return total;
  return Math.max(0, Math.min(total, Math.floor(((nowMs - sim.startMs) / MS_PER_SECOND) * SERIES_HZ)));
}

function eventCounts(sim: SimulatedSession, last: number): Record<RoadEventType, number> {
  const counts: Record<RoadEventType, number> = { pothole: 0, speed_bump: 0, rail_joint: 0 };
  for (const event of sim.events) if (event.sampleIndex <= last) counts[event.type]++;
  return counts;
}

function validFraction(spec: SessionSpec): number {
  if (spec.quality === "bad") return 0.31;
  if (spec.quality === "degraded") return 0.71;
  return 0.93 + 0.06 * unitHash(`${spec.sessionId}:valid`);
}

export function sessionSummary(sim: SimulatedSession, nowMs: number = Date.now()): SessionSummary {
  const { spec } = sim;
  const last = lastSampleIndex(sim, nowMs);
  const msdv = sim.msdv[last];
  return {
    sessionId: spec.sessionId,
    source: spec.source,
    isMock: true,
    replayOf: spec.replayOf,
    deviceId: spec.deviceId,
    vehicle: spec.vehicle,
    mount: spec.mount,
    people: spec.people,
    audioEnabled: spec.audioEnabled,
    startedAt: new Date(sim.t[0]).toISOString(),
    endedAt: spec.live ? null : new Date(sim.t[last]).toISOString(),
    durationS: (sim.t[last] - sim.t[0]) / MS_PER_SECOND,
    distanceM: sim.s[last],
    status: spec.live ? "live" : "complete",
    qualityStatus: spec.quality,
    validFraction: validFraction(spec),
    includeInAgg: isIncluded(spec),
    exclusionReasons: exclusionReasons(spec),
    roughnessEligible: isRoughnessEligible(spec),
    sicknessExperimental: isSicknessExperimental(spec),
    msdvZ: msdv,
    msiPct: msdv / 3,
    eventCounts: eventCounts(sim, last),
    ratingsCount: sim.ratings.filter((r) => r.sampleIndex <= last).length,
  };
}

function stream(rateHz: number, durationS: number, key: string, gaps = 0, maxGapS?: number): StreamQuality {
  const jitter = unitHash(key);
  const measured = rateHz >= 50 ? rateHz - 0.05 - jitter * 0.25 : rateHz * (0.98 + jitter * 0.03);
  return {
    rows: Math.round(measured * durationS),
    rateHz: measured,
    expectedHz: rateHz,
    maxGapS: maxGapS ?? (1 / rateHz) * (1.8 + jitter),
    gapsOver1s: gaps,
  };
}

function sessionQuality(sim: SimulatedSession, last: number): SessionQuality {
  const { spec } = sim;
  const durationS = (sim.t[last] - sim.t[0]) / MS_PER_SECOND;
  const id = spec.sessionId;
  const degraded = spec.quality === "degraded";
  const bad = spec.quality === "bad";
  const streams: Record<string, StreamQuality> = {
    device_motion: stream(100, durationS, `${id}:dm`, degraded ? 2 : 0, degraded ? 1.42 : undefined),
    accel_raw: stream(100, durationS, `${id}:acc`, degraded ? 2 : 0, degraded ? 1.41 : undefined),
    gyro_raw: stream(100, durationS, `${id}:gyr`, degraded ? 2 : 0, degraded ? 1.41 : undefined),
    mag_raw: stream(50, durationS, `${id}:mag`),
    location: bad ? stream(0.4, durationS, `${id}:loc`, 9, 14.2) : stream(1, durationS, `${id}:loc`),
    altimeter: stream(1, durationS, `${id}:alt`),
    audio_level: stream(10, durationS, `${id}:aud`),
    device: stream(0.2, durationS, `${id}:dev`),
  };
  const fixes = streams.location.rows;
  const isLive = spec.live;
  return {
    streams,
    gps: {
      fixes,
      medianHAccM: bad ? 18.4 : 3.9 + unitHash(`${id}:hacc`) * 1.4,
      p95HAccM: bad ? 48.2 : 6.5 + unitHash(`${id}:hacc95`) * 3,
    },
    validFraction: validFraction(spec),
    invalidSeconds: {
      phone_moved: degraded ? 20 : 0,
      gravity_drift: degraded ? 35 : bad ? 120 : 0,
      gyro_gps_mismatch: Math.round(unitHash(`${id}:gyro`) * 12) + (bad ? 140 : 0),
      gps_poor: bad ? Math.round(durationS * 0.55) : Math.round(unitHash(`${id}:gpspoor`) * 8),
    },
    rejectedBatches: isLive ? 1 : 0,
    lateBatches: isLive ? 2 : 0,
    duplicateBatches: isLive ? 3 : 0,
  };
}

function spearman(xs: number[], ys: number[]): number | null {
  if (xs.length < 3) return null;
  const rank = (values: number[]) => {
    const order = values.map((value, index) => ({ value, index })).sort((a, b) => a.value - b.value);
    const ranks = new Array<number>(values.length);
    let i = 0;
    while (i < order.length) {
      let j = i;
      while (j + 1 < order.length && order[j + 1].value === order[i].value) j++;
      for (let k = i; k <= j; k++) ranks[order[k].index] = (i + j) / 2;
      i = j + 1;
    }
    return ranks;
  };
  const rx = rank(xs);
  const ry = rank(ys);
  const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;
  const mx = mean(rx);
  const my = mean(ry);
  let num = 0;
  let dx = 0;
  let dy = 0;
  for (let i = 0; i < rx.length; i++) {
    num += (rx[i] - mx) * (ry[i] - my);
    dx += (rx[i] - mx) ** 2;
    dy += (ry[i] - my) ** 2;
  }
  return dx > 0 && dy > 0 ? num / Math.sqrt(dx * dy) : null;
}

export function sessionDetail(sim: SimulatedSession, nowMs: number = Date.now()): SessionDetail {
  const last = lastSampleIndex(sim, nowMs);
  const summary = sessionSummary(sim, nowMs);
  const ratings = sim.ratings.filter((r) => r.sampleIndex <= last).map(({ tUtc, value, msdvSoFar }) => ({ tUtc, value, msdvSoFar }));
  return {
    ...summary,
    quality: sessionQuality(sim, last),
    detection: detectionMetrics(sim, last),
    sickness: {
      msdvZ: summary.msdvZ,
      msiPct: summary.msiPct,
      ratings,
      spearman: spearman(
        ratings.map((r) => r.msdvSoFar ?? 0),
        ratings.map((r) => r.value),
      ),
    },
    processedAt: sim.spec.live ? null : new Date(sim.t[last] + PROCESSING_DELAY_MS).toISOString(),
    processorVersion: PROCESSOR_VERSION,
  };
}

export function qualityRow(sim: SimulatedSession, nowMs: number = Date.now()): QualityRow {
  return { ...sessionSummary(sim, nowMs), quality: sessionQuality(sim, lastSampleIndex(sim, nowMs)) };
}

export { isIncluded };
