import { MS_PER_SECOND, SECONDS_PER_MINUTE } from "@/constants/units";
import type { ProcessingStatus, RoadEventType } from "@/types/common";
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
/** The finalize job finishes this long after a trip ends (trip-end detection + one pass over the trip). */
const PROCESSING_DELAY_MS = 4 * SECONDS_PER_MINUTE * MS_PER_SECOND;
/** Phone → ingest function: the 2 s batch window plus the upload. */
const UPLOAD_DELAY_S = 2.5;
/** Ingest → Event Hubs → stream processor → database. */
const PROCESSING_LAG_S = 1;

export interface MockDataset {
  sims: Map<string, SimulatedSession>;
}

let cached: MockDataset | null = null;

/** Start time of a spec: fixed, relative to page load (live), or ending just before page load. */
function startOf(spec: SessionSpec, loadMs: number): number {
  if (spec.startedAt) return Date.parse(spec.startedAt);
  if (spec.endedBeforeLoadMs !== null) {
    const probe = simulateSession(spec, 0);
    return loadMs - spec.endedBeforeLoadMs - probe.t[probe.t.length - 1];
  }
  return loadMs - (LIVE_HEAD_START_MS[spec.sessionId] ?? 0);
}

export function getDataset(): MockDataset {
  if (cached) return cached;
  const loadMs = Date.now();
  const sims = new Map<string, SimulatedSession>();
  for (const spec of SESSION_SPECS) sims.set(spec.sessionId, simulateSession(spec, startOf(spec, loadMs)));
  cached = { sims };
  return cached;
}

// ---------------------------------------------------------------------------------------------
// Live timing: what the backend has received and processed at a given moment.

interface LiveTiming {
  /** Seconds since trip start of the newest sample the processor has written. */
  processedS: number;
  /** Seconds since trip start at which the ingest function received the batch holding that sample. */
  receivedS: number;
}

/**
 * Normally data shows up a few seconds after it was recorded. In a dead zone the phone keeps batches
 * on disk, so nothing new arrives; when the signal is back the backlog arrives in a burst and is
 * processed faster than real time until it has caught up (plan 02 §5 "Gaps and late data").
 */
function liveTiming(sim: SimulatedSession, nowMs: number): LiveTiming {
  const elapsedS = (nowMs - sim.startMs) / MS_PER_SECOND;
  const normal = { processedS: elapsedS - UPLOAD_DELAY_S - PROCESSING_LAG_S, receivedS: elapsedS - PROCESSING_LAG_S };
  const zone = sim.spec.deadZone;
  if (!zone) return normal;
  const cycleStartS = Math.floor(elapsedS / zone.cycleS) * zone.cycleS;
  const localS = elapsedS - cycleStartS;
  const lostAtS = cycleStartS + zone.startS - UPLOAD_DELAY_S;
  if (localS < zone.startS) return normal;
  if (localS < zone.startS + zone.durationS) return { processedS: lostAtS - PROCESSING_LAG_S, receivedS: lostAtS };
  const caughtUpS = lostAtS + (localS - zone.startS - zone.durationS) * zone.catchUpFactor;
  if (caughtUpS >= normal.processedS) return normal;
  // Catching up: the batches being processed now arrived just now, but hold samples from minutes ago.
  return { processedS: caughtUpS, receivedS: elapsedS - PROCESSING_LAG_S };
}

/** Index of the newest sample the backend has processed "now" (live sessions grow in real time). */
export function lastSampleIndex(sim: SimulatedSession, nowMs: number = Date.now()): number {
  const total = sim.t.length - 1;
  if (!sim.spec.live) return total;
  return Math.max(0, Math.min(total, Math.floor(liveTiming(sim, nowMs).processedS * SERIES_HZ)));
}

/** When the ingest function received the newest processed sample (epoch ms). */
export function receivedAtMs(sim: SimulatedSession, nowMs: number = Date.now()): number {
  if (!sim.spec.live) return sim.t[sim.t.length - 1];
  const lastSampleMs = sim.t[sim.t.length - 1];
  return Math.min(sim.startMs + liveTiming(sim, nowMs).receivedS * MS_PER_SECOND, lastSampleMs + UPLOAD_DELAY_S * MS_PER_SECOND);
}

/** Whether a live session is still being recorded (its simulation has samples left). */
export function isStillLive(sim: SimulatedSession, nowMs: number = Date.now()): boolean {
  return sim.spec.live && lastSampleIndex(sim, nowMs) < sim.t.length - 1;
}

/** End of the trip (its last sample), or null while it is still being recorded. */
function endedAtMs(sim: SimulatedSession, nowMs: number): number | null {
  return isStillLive(sim, nowMs) ? null : sim.t[sim.t.length - 1];
}

/** When the finalize job finished with the trip, or null if it hasn't yet. */
export function processedAt(sim: SimulatedSession, nowMs: number = Date.now()): number | null {
  const ended = endedAtMs(sim, nowMs);
  if (ended === null) return null;
  const done = ended + PROCESSING_DELAY_MS;
  return done <= nowMs ? done : null;
}

/** `live` while recording, `processing` until finalized, `complete` after (plan 02 §8). */
export function processingStatus(sim: SimulatedSession, nowMs: number = Date.now()): ProcessingStatus {
  if (isStillLive(sim, nowMs)) return "live";
  return processedAt(sim, nowMs) === null ? "processing" : "complete";
}

// ---------------------------------------------------------------------------------------------
// Aggregation rules (plan 02 §8, §10; dashboard/API.md).

const isRoughnessEligible = (spec: SessionSpec) => spec.contextKnown && spec.mount.rigid && !spec.mount.handheld;
const isSicknessExperimental = (spec: SessionSpec) => !spec.contextKnown || !spec.mount.rigid || spec.mount.handheld;

/** Why a trip is (partly) kept out of the aggregated map. */
function exclusionReasons(sim: SimulatedSession, nowMs: number): ExclusionReason[] {
  const { spec } = sim;
  const finalized = processingStatus(sim, nowMs) === "complete";
  const reasons: ExclusionReason[] = [];
  if (spec.source === "replay") reasons.push("replay");
  else if (!finalized) reasons.push(spec.source === "live" ? "live_only" : "processing");
  if (spec.quality === "bad") reasons.push("bad_quality");
  if (!spec.contextKnown) {
    reasons.push("unknown_context");
    return reasons;
  }
  if (!spec.mount.rigid) reasons.push("not_rigid");
  if (spec.mount.handheld) reasons.push("handheld");
  return reasons;
}

/** Only finalized trips with known context that pass the quality rules count; replays never do. */
export function isIncluded(sim: SimulatedSession, nowMs: number = Date.now()): boolean {
  const { spec } = sim;
  return (
    spec.source !== "replay" &&
    spec.quality !== "bad" &&
    spec.contextKnown &&
    processingStatus(sim, nowMs) === "complete"
  );
}

let cachedAggregation: { key: string; result: AggregationResult } | null = null;

/**
 * The aggregation step runs again whenever another trip is finalized (as at the end of every finalize
 * job), so the result depends on which trips are included at `nowMs`.
 */
export function getAggregation(nowMs: number = Date.now()): AggregationResult {
  const included = [...getDataset().sims.values()].filter((sim) => isIncluded(sim, nowMs));
  const key = included.map((sim) => sim.spec.sessionId).join(",");
  if (cachedAggregation?.key === key) return cachedAggregation.result;
  const fittedTimes = included.flatMap((sim) => processedAt(sim, nowMs) ?? []);
  const fittedAt = fittedTimes.length > 0 ? new Date(Math.max(...fittedTimes)).toISOString() : null;
  const result = aggregate(
    included.map((sim) => ({
      sim,
      roughnessEligible: isRoughnessEligible(sim.spec),
      sicknessEligible: sim.spec.contextKnown, // D41: hand-held trips count for sickness
    })),
    fittedAt,
  );
  cachedAggregation = { key, result };
  return result;
}

/** Counts the events recorded so far, so counts match the dots on the map. */
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
  const ended = endedAtMs(sim, nowMs);
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
    endedAt: ended === null ? null : new Date(ended).toISOString(),
    durationS: (sim.t[last] - sim.t[0]) / MS_PER_SECOND,
    distanceM: sim.s[last],
    status: processingStatus(sim, nowMs),
    incomplete: spec.incomplete,
    qualityStatus: spec.quality,
    validFraction: validFraction(spec),
    includeInAgg: isIncluded(sim, nowMs),
    exclusionReasons: exclusionReasons(sim, nowMs),
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
  // Only streamed trips have live batches; a few are rejected, late or repeated on a real network.
  const streamed = spec.source !== "upload";
  const batchStat = (salt: string, max: number) => (streamed ? Math.floor(unitHash(`${id}:${salt}`) * (max + 1)) : 0);
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
    rejectedBatches: batchStat("rejected", 2),
    lateBatches: batchStat("late", 4),
    duplicateBatches: batchStat("duplicate", 6),
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
  const processed = processedAt(sim, nowMs);
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
    processedAt: processed === null ? null : new Date(processed).toISOString(),
    processorVersion: PROCESSOR_VERSION,
  };
}

export function qualityRow(sim: SimulatedSession, nowMs: number = Date.now()): QualityRow {
  return { ...sessionSummary(sim, nowMs), quality: sessionQuality(sim, lastSampleIndex(sim, nowMs)) };
}

