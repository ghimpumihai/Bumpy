import { MS_TO_KMH, SECONDS_PER_HOUR } from "@/constants/units";
import type { VehicleType } from "@/types/common";
import type { AggregationInfo } from "@/types/overview";
import type { RoughnessMethod, SegmentAggregate, SegmentSicknessSplit, VehicleFilter } from "@/types/segments";

import { POTHOLE_MIN_SPEED_MS, type SimulatedObservation, type SimulatedSession } from "./simulate";

/** Roughness is reported for this reference speed (36 km/h = 10 m/s). */
export const REFERENCE_SPEED_KMH = 36;
const REFERENCE_SPEED_MS = REFERENCE_SPEED_KMH / MS_TO_KMH;
/** Below this, roughness says more about the engine than the road. */
const MIN_ROUGHNESS_SPEED_MS = 2;
/** Fewer than this many observations in multi-pass segments → the fit is not trusted. */
const MIN_WITHIN_OBSERVATIONS = 30;
const SINGULAR_DETERMINANT = 1e-9;
const REFERENCE_VEHICLE: VehicleType = "car";
/** MSI (% who may vomit) ≈ MSDV / 3 (plan 02 §9). */
const MSDV_PER_MSI_PERCENT = 3;

/** Crowd confirmation: a pothole needs at least `minHits` passes with a detection and `minRatio` of all passes. */
export const POTHOLE_THRESHOLDS: Record<VehicleFilter, { minHits: number; minRatio: number }> = {
  all: { minHits: 2, minRatio: 0.5 },
  car: { minHits: 2, minRatio: 0.5 },
  bus: { minHits: 2, minRatio: 0.4 },
  tram: { minHits: 3, minRatio: 0.6 },
};

export interface AggregationInput {
  sim: SimulatedSession;
  roughnessEligible: boolean;
  sicknessEligible: boolean;
}

interface Row {
  obs: SimulatedObservation;
  vehicle: VehicleType;
  input: AggregationInput;
  /** Percent rank of this observation's roughness within its session, 0–1. */
  percentile: number | null;
}

export interface AggregationResult {
  info: AggregationInfo;
  segments: Map<string, Map<VehicleFilter, SegmentAggregate>>;
  sicknessBySeat: Map<string, SegmentSicknessSplit[]>;
}

/** Solves a small dense linear system with Gaussian elimination; `null` if singular. */
function solve(matrix: number[][], rhs: number[]): number[] | null {
  const size = rhs.length;
  const a = matrix.map((row, i) => [...row, rhs[i]]);
  for (let col = 0; col < size; col++) {
    let pivot = col;
    for (let r = col + 1; r < size; r++) if (Math.abs(a[r][col]) > Math.abs(a[pivot][col])) pivot = r;
    if (Math.abs(a[pivot][col]) < SINGULAR_DETERMINANT) return null;
    [a[col], a[pivot]] = [a[pivot], a[col]];
    for (let r = 0; r < size; r++) {
      if (r === col) continue;
      const factor = a[r][col] / a[col][col];
      for (let c = col; c <= size; c++) a[r][c] -= factor * a[col][c];
    }
  }
  return a.map((row, i) => row[size] / row[i]);
}

/**
 * Fixed-effects fit of log(roughness) = segment + vehicle + β·log(speed): demeaning within each
 * segment removes the segment effects (Frisch–Waugh), leaving a small system for β and the vehicle effects.
 */
function fitRoughnessModel(rows: Row[]): { beta: number; effects: Record<string, number> } | null {
  const usable = rows.filter((r) => r.input.roughnessEligible && r.obs.roughnessRms && r.obs.meanSpeedMs >= MIN_ROUGHNESS_SPEED_MS);
  const vehicles = [...new Set(usable.map((r) => r.vehicle))].filter((v) => v !== REFERENCE_VEHICLE).sort();
  const byCell = new Map<string, Row[]>();
  for (const row of usable) byCell.set(row.obs.cell, [...(byCell.get(row.obs.cell) ?? []), row]);

  const features = (r: Row) => [Math.log(r.obs.meanSpeedMs / REFERENCE_SPEED_MS), ...vehicles.map((v) => (r.vehicle === v ? 1 : 0))];
  const size = 1 + vehicles.length;
  const xtx = Array.from({ length: size }, () => new Array<number>(size).fill(0));
  const xty = new Array<number>(size).fill(0);
  let within = 0;
  for (const group of byCell.values()) {
    if (group.length < 2) continue;
    within += group.length;
    const xs = group.map(features);
    const ys = group.map((r) => Math.log(r.obs.roughnessRms ?? 1));
    const meanX = xs[0].map((_, j) => xs.reduce((sum, x) => sum + x[j], 0) / xs.length);
    const meanY = ys.reduce((sum, y) => sum + y, 0) / ys.length;
    xs.forEach((x, i) => {
      const dx = x.map((value, j) => value - meanX[j]);
      const dy = ys[i] - meanY;
      for (let a = 0; a < size; a++) {
        xty[a] += dx[a] * dy;
        for (let b = 0; b < size; b++) xtx[a][b] += dx[a] * dx[b];
      }
    });
  }
  if (within < MIN_WITHIN_OBSERVATIONS) return null;
  const solution = solve(xtx, xty);
  if (!solution) return null;
  const effects: Record<string, number> = { [REFERENCE_VEHICLE]: 0 };
  vehicles.forEach((v, i) => (effects[v] = solution[i + 1]));
  return { beta: solution[0], effects };
}

const isRoughUsable = (r: Row) =>
  r.input.roughnessEligible && Boolean(r.obs.roughnessRms) && r.obs.meanSpeedMs >= MIN_ROUGHNESS_SPEED_MS;

/** Per session, over the passes the percentile mean uses (idle ones don't shift the moving ones); ties get their average rank. */
function percentRanks(rows: Row[]) {
  const bySession = new Map<string, Row[]>();
  for (const row of rows) {
    if (!isRoughUsable(row)) continue;
    const id = row.input.sim.spec.sessionId;
    bySession.set(id, [...(bySession.get(id) ?? []), row]);
  }
  for (const group of bySession.values()) {
    const sorted = [...group].sort((a, b) => (a.obs.roughnessRms ?? 0) - (b.obs.roughnessRms ?? 0));
    const n = sorted.length;
    let i = 0;
    while (i < n) {
      let j = i;
      while (j + 1 < n && sorted[j + 1].obs.roughnessRms === sorted[i].obs.roughnessRms) j++;
      for (let k = i; k <= j; k++) sorted[k].percentile = n > 1 ? (i + j) / 2 / (n - 1) : 0.5;
      i = j + 1;
    }
  }
}

const mean = (values: number[]) => (values.length > 0 ? values.reduce((a, b) => a + b, 0) / values.length : null);

function aggregateGroup(
  cell: string,
  filter: VehicleFilter,
  rows: Row[],
  method: RoughnessMethod,
  model: { beta: number; effects: Record<string, number> } | null,
): SegmentAggregate {
  const sessions = new Set(rows.map((r) => r.input.sim.spec.sessionId));
  const rough = rows.filter((r) => r.input.roughnessEligible && r.obs.roughnessRms && r.obs.meanSpeedMs >= MIN_ROUGHNESS_SPEED_MS);
  const normalized =
    model && rough.length > 0
      ? Math.exp(
          mean(
            rough.map(
              (r) =>
                Math.log(r.obs.roughnessRms ?? 1) -
                (model.effects[r.vehicle] ?? 0) -
                model.beta * Math.log(r.obs.meanSpeedMs / REFERENCE_SPEED_MS),
            ),
          ) ?? 0,
        )
      : null;
  const pctl = mean(rough.flatMap((r) => (r.percentile === null ? [] : [r.percentile])));

  const potholePasses = rows.filter((r) => r.input.roughnessEligible && r.obs.meanSpeedMs > POTHOLE_MIN_SPEED_MS);
  const potholeHits = potholePasses.filter((r) => r.obs.potholeCount > 0).length;
  const ratio = potholePasses.length > 0 ? potholeHits / potholePasses.length : null;
  const threshold = POTHOLE_THRESHOLDS[filter];

  const sick = rows.filter((r) => r.input.sicknessEligible);
  const sickDuration = sick.reduce((sum, r) => sum + r.obs.durationS, 0);
  const awRms = sickDuration > 0 ? Math.sqrt(sick.reduce((sum, r) => sum + r.obs.awRms ** 2 * r.obs.durationS, 0) / sickDuration) : null;

  return {
    h3: cell,
    vehicleType: filter,
    nSessions: sessions.size,
    nPasses: rows.length,
    meanSpeedKmh: mean(rows.map((r) => r.obs.meanSpeedMs * MS_TO_KMH)),
    roughness: method === "model" ? normalized : null,
    roughnessPctl: pctl,
    roughnessMethod: rough.length > 0 ? method : "none",
    potholeHits,
    potholePasses: potholePasses.length,
    potholeRatio: ratio,
    potholeConfirmed: potholeHits >= threshold.minHits && (ratio ?? 0) >= threshold.minRatio,
    sicknessAwRms: awRms,
    msi1hPct: awRms === null ? null : (awRms * Math.sqrt(SECONDS_PER_HOUR)) / MSDV_PER_MSI_PERCENT,
    sicknessSessions: new Set(sick.map((r) => r.input.sim.spec.sessionId)).size,
  };
}

function sicknessSplits(rows: Row[]): SegmentSicknessSplit[] {
  const groups = new Map<string, Row[]>();
  for (const row of rows) {
    if (!row.input.sicknessEligible) continue;
    const { people } = row.input.sim.spec;
    const key = [row.vehicle, people.raterSeat, people.raterPosture].join("|");
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return [...groups.values()].map((group) => {
    const duration = group.reduce((sum, r) => sum + r.obs.durationS, 0);
    const awRms = Math.sqrt(group.reduce((sum, r) => sum + r.obs.awRms ** 2 * r.obs.durationS, 0) / duration);
    const { people } = group[0].input.sim.spec;
    return {
      vehicleType: group[0].vehicle,
      raterSeat: people.raterSeat,
      raterPosture: people.raterPosture,
      sicknessAwRms: awRms,
      msi1hPct: (awRms * Math.sqrt(SECONDS_PER_HOUR)) / MSDV_PER_MSI_PERCENT,
      nSessions: new Set(group.map((r) => r.input.sim.spec.sessionId)).size,
    };
  });
}

/** Plays the role of the aggregation step + the `segment_agg` materialized view (plan 02 §8–9). */
export function aggregate(inputs: AggregationInput[], fittedAt: string | null): AggregationResult {
  const rows: Row[] = inputs.flatMap((input) =>
    input.sim.observations.map((obs) => ({ obs, vehicle: input.sim.spec.vehicle.type, input, percentile: null })),
  );
  percentRanks(rows);
  const model = fitRoughnessModel(rows);
  const method: RoughnessMethod = rows.length === 0 ? "none" : model ? "model" : "percentile";

  const byCell = new Map<string, Row[]>();
  for (const row of rows) byCell.set(row.obs.cell, [...(byCell.get(row.obs.cell) ?? []), row]);

  const segments = new Map<string, Map<VehicleFilter, SegmentAggregate>>();
  const sicknessBySeat = new Map<string, SegmentSicknessSplit[]>();
  for (const [cell, cellRows] of byCell) {
    const perFilter = new Map<VehicleFilter, SegmentAggregate>();
    perFilter.set("all", aggregateGroup(cell, "all", cellRows, method, model));
    for (const filter of ["car", "bus", "tram"] as const) {
      const subset = cellRows.filter((r) => r.vehicle === filter);
      if (subset.length > 0) perFilter.set(filter, aggregateGroup(cell, filter, subset, method, model));
    }
    segments.set(cell, perFilter);
    sicknessBySeat.set(cell, sicknessSplits(cellRows));
  }

  return {
    info: {
      method,
      beta: model?.beta ?? null,
      refSpeedKmh: REFERENCE_SPEED_KMH,
      vehicleEffects: model?.effects ?? {},
      fittedAt,
    },
    segments,
    sicknessBySeat,
  };
}
