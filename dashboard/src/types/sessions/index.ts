import type { Feature, FeatureCollection, LineString, Point } from "geojson";

import type {
  EpochMs,
  IsoDateTime,
  ProcessingStatus,
  QualityStatus,
  RoadEventType,
  SessionSource,
  VehicleType,
} from "@/types/common";

/** Why a session is kept out of the aggregated map (plan 02 §10). */
export const ExclusionReason = {
  REPLAY: "replay",
  /** A streamed trip that is not finalized yet (still recording or being processed). */
  LIVE_ONLY: "live_only",
  /** An uploaded folder that is still being processed. */
  PROCESSING: "processing",
  BAD_QUALITY: "bad_quality",
  /** session.json never arrived (spec §6.1), so the vehicle and mount are unknown. */
  UNKNOWN_CONTEXT: "unknown_context",
  NOT_RIGID: "not_rigid",
  HANDHELD: "handheld",
} as const;
export type ExclusionReason = (typeof ExclusionReason)[keyof typeof ExclusionReason];

export const RaterPosture = {
  SEATED: "seated",
  STANDING: "standing",
} as const;
export type RaterPosture = (typeof RaterPosture)[keyof typeof RaterPosture];

export interface Vehicle {
  type: VehicleType;
  makeModel: string;
  /** Bus/tram line, `null` for other vehicles. */
  line: string | null;
}

export interface Mount {
  location: string;
  phoneOrientation: string;
  rigid: boolean;
  handheld: boolean;
}

export interface People {
  operatorSeat: string;
  raterSeat: string;
  raterPosture: RaterPosture;
  passengerCount: number;
}

export interface RoadEventCounts {
  pothole: number;
  speed_bump: number;
  rail_joint: number;
}

/** One row of `GET /api/sessions`. */
export interface SessionSummary {
  sessionId: string;
  source: SessionSource;
  /** Session recorded with synthetic sensors / generated as mock data (`session.json` `syntheticSensors`). */
  isMock: boolean;
  /** For replays: the session that was re-sent. */
  replayOf: string | null;
  deviceId: string | null;
  vehicle: Vehicle;
  mount: Mount;
  people: People;
  audioEnabled: boolean;
  startedAt: IsoDateTime;
  endedAt: IsoDateTime | null;
  durationS: number;
  distanceM: number;
  status: ProcessingStatus;
  /** Closed without the app's Stop message (crash, dead phone) after 15 min without batches; gaps are marked. */
  incomplete: boolean;
  qualityStatus: QualityStatus;
  /** Fraction (0–1) of moving time that passed the quality checks. */
  validFraction: number | null;
  includeInAgg: boolean;
  exclusionReasons: ExclusionReason[];
  /** Rigid, non-handheld mount: counted for roughness. */
  roughnessEligible: boolean;
  /** Non-rigid or handheld: sickness numbers are experimental. */
  sicknessExperimental: boolean;
  /** ISO 2631-1 motion sickness dose value (vertical), m/s^1.5. */
  msdvZ: number | null;
  /** Predicted motion sickness incidence, % ≈ MSDV / 3. */
  msiPct: number | null;
  eventCounts: RoadEventCounts;
}

export interface SessionListResponse {
  sessions: SessionSummary[];
}

export interface StreamQuality {
  rows: number;
  rateHz: number | null;
  expectedHz: number | null;
  maxGapS: number | null;
  gapsOver1s: number;
}

export interface GpsQuality {
  fixes: number;
  medianHAccM: number | null;
  p95HAccM: number | null;
}

/** Seconds of data marked invalid, per reason (plan 02 §9 step 3). */
export interface InvalidSeconds {
  phone_moved: number;
  gravity_drift: number;
  gyro_gps_mismatch: number;
  gps_poor: number;
}

export interface SessionQuality {
  streams: Record<string, StreamQuality>;
  gps: GpsQuality;
  validFraction: number | null;
  invalidSeconds: InvalidSeconds;
  /** Live batches the ingest API rejected for this session. */
  rejectedBatches: number;
  /** Live batches that arrived after newer ones (archived, not processed). */
  lateBatches: number;
  /** Repeated live batches ignored by the database (`ON CONFLICT DO NOTHING`). */
  duplicateBatches: number;
}

/** Detections scored against manual taps within ±1.5 s (plan 02 §9 step 5). True/false positives
 * count detections, false negatives count taps: precision is over detections, recall over taps. */
export interface DetectionScore {
  truePositives: number;
  falsePositives: number;
  falseNegatives: number;
  precision: number | null;
  recall: number | null;
}

export interface DetectionMetrics {
  pothole: DetectionScore;
  speed_bump: DetectionScore;
}

/** The calculated motion-sickness dose of the whole trip (ISO 2631-1); no passenger ratings (D47). */
export interface SicknessSummary {
  msdvZ: number | null;
  msiPct: number | null;
}

/** `GET /api/sessions/{id}`. */
export interface SessionDetail extends SessionSummary {
  quality: SessionQuality;
  detection: DetectionMetrics | null;
  sickness: SicknessSummary;
  processedAt: IsoDateTime | null;
  processorVersion: string | null;
}

/** `GET /api/sessions/{id}/series`: columnar, about 5 Hz. */
export interface SessionSeries {
  t: EpochMs[];
  /** Vertical acceleration, m/s², gravity removed. */
  aVert: number[];
  /** Lateral (sideways) acceleration, low-passed, m/s². */
  aLat: number[];
  /** Longitudinal acceleration, low-passed, m/s². */
  aLon: number[];
  /** m/s; `null` where GPS had no valid speed. */
  speed: (number | null)[];
  /** Cumulative MSDV so far, m/s^1.5. */
  msdv: number[];
}

export interface TrackProperties {
  sessionId: string;
  /** Epoch ms per coordinate. */
  times: EpochMs[];
  /** m/s per coordinate. */
  speeds: (number | null)[];
  /** Metres removed at each end for privacy. */
  trimmedM: number;
}

/** `GET /api/sessions/{id}/track`. */
export type SessionTrack = Feature<LineString, TrackProperties>;

export interface RoadEventProperties {
  id: string;
  sessionId: string;
  type: RoadEventType;
  tUtc: IsoDateTime;
  speedKmh: number | null;
  /** m/s²: peak |band-passed (1–30 Hz) vertical acceleration|, at the jolt (pothole) or at either axle (speed bump). */
  magnitude: number;
  /** 0–1. */
  confidence: number;
  /** A manual tap of the same type was within ±1.5 s. */
  matchedLabel: boolean;
  vehicleType: VehicleType;
}

/** `GET /api/sessions/{id}/events` and `GET /api/events`. */
export type RoadEventCollection = FeatureCollection<Point, RoadEventProperties>;

export interface SessionLabel {
  tUtc: IsoDateTime;
  type: string;
  value: string | null;
  note: string | null;
}

/** `GET /api/sessions/{id}/labels`. */
export interface SessionLabelsResponse {
  labels: SessionLabel[];
}

/** One row of `GET /api/quality`: the data-quality panel for every session. */
export interface QualityRow extends SessionSummary {
  quality: SessionQuality;
}

export interface QualityListResponse {
  sessions: QualityRow[];
}

/** Optional filters of `GET /api/sessions`. */
export interface SessionListFilters {
  source?: SessionSource;
  vehicle?: VehicleType;
}

/** Health of one recorded stream, as on the phone's summary screen (also used for live-data freshness). */
export const StreamStatus = {
  OK: "ok",
  WARN: "warn",
  PROBLEM: "problem",
} as const;
export type StreamStatus = (typeof StreamStatus)[keyof typeof StreamStatus];

/** Properties of one coloured piece of a session track. */
export interface TrackPieceProperties {
  speedKmh: number | null;
}
