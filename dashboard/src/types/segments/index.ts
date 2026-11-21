import type { FeatureCollection, MultiLineString, Polygon } from "geojson";

import type { IsoDateTime, VehicleType } from "@/types/common";
import type { RaterPosture } from "@/types/sessions";

/** Vehicle filter of the aggregated map: one vehicle type, or every vehicle combined. */
export const VehicleFilter = {
  ALL: "all",
  CAR: "car",
  BUS: "bus",
  TRAM: "tram",
} as const;
export type VehicleFilter = (typeof VehicleFilter)[keyof typeof VehicleFilter];

/**
 * How roughness was normalized across vehicles (plan 02 §9):
 * `model` = log(roughness) = segment + vehicle + β·log(speed); `percentile` = per-session percentiles fallback.
 */
export const RoughnessMethod = {
  MODEL: "model",
  PERCENTILE: "percentile",
  NONE: "none",
} as const;
export type RoughnessMethod = (typeof RoughnessMethod)[keyof typeof RoughnessMethod];

/** One row of the `segment_agg` materialized view (segment × vehicle type). */
export interface SegmentAggregate {
  h3: string;
  vehicleType: VehicleFilter;
  nSessions: number;
  nPasses: number;
  meanSpeedKmh: number | null;
  /** Normalized roughness: vertical RMS (1–30 Hz) a reference car would feel at the reference speed, m/s². */
  roughness: number | null;
  /** Mean per-session percentile of raw roughness, 0–1 (fallback method). */
  roughnessPctl: number | null;
  roughnessMethod: RoughnessMethod;
  /** Passes above 15 km/h with a detected pothole. */
  potholeHits: number;
  /** Passes above 15 km/h. */
  potholePasses: number;
  /** potholeHits / potholePasses. */
  potholeRatio: number | null;
  /** Crowd-confirmed: at least k of n passes, thresholds per vehicle type. */
  potholeConfirmed: boolean;
  /** Frequency-weighted (Wf) vertical RMS, m/s². Not normalized: it is what passengers feel. */
  sicknessAwRms: number | null;
  /** Predicted % of unadapted people who may vomit after one hour of this motion. */
  msi1hPct: number | null;
  /** Sessions with a rigid mount that contributed to the sickness numbers. */
  sicknessSessions: number;
}

/** `GET /api/segments?vehicle=…`: H3 hexagons with their aggregate. */
export type SegmentCollection = FeatureCollection<Polygon, SegmentAggregate>;

export interface SegmentObservation {
  sessionId: string;
  vehicleType: VehicleType;
  tStart: IsoDateTime;
  speedKmh: number | null;
  /** Raw vertical RMS (1–30 Hz) as measured, m/s². */
  roughnessRms: number | null;
  awRms: number | null;
  potholeCount: number;
  includedInAgg: boolean;
}

export interface SegmentSicknessSplit {
  vehicleType: VehicleType;
  raterSeat: string;
  raterPosture: RaterPosture;
  sicknessAwRms: number | null;
  msi1hPct: number | null;
  nSessions: number;
}

/** `GET /api/heat`: one line per aggregated trip; the dashboard counts the overlap. */
export type HeatCollection = FeatureCollection<MultiLineString, Record<string, never>>;

/** `GET /api/segments/{h3}`. */
export interface SegmentDetail {
  h3: string;
  center: { lon: number; lat: number };
  byVehicle: SegmentAggregate[];
  sicknessBySeat: SegmentSicknessSplit[];
  observations: SegmentObservation[];
  updatedAt: IsoDateTime | null;
}
