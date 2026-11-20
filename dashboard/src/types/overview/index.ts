import type { IsoDateTime } from "@/types/common";
import type { RoughnessMethod } from "@/types/segments";

export interface SessionCounts {
  total: number;
  upload: number;
  live: number;
  replay: number;
  includedInAgg: number;
  mock: number;
}

/** Result of the cross-vehicle roughness fit (plan 02 §9). */
export interface AggregationInfo {
  method: RoughnessMethod;
  /** Speed exponent β in log(roughness) = segment + vehicle + β·log(speed). */
  beta: number | null;
  refSpeedKmh: number;
  /** log-scale vehicle effects relative to the reference vehicle (car = 0). */
  vehicleEffects: Record<string, number>;
  fittedAt: IsoDateTime | null;
}

/** `GET /api/overview`. */
export interface Overview {
  sessions: SessionCounts;
  distanceKm: number;
  segments: number;
  confirmedPotholes: number;
  speedBumps: number;
  lastProcessedAt: IsoDateTime | null;
  aggregation: AggregationInfo;
}
