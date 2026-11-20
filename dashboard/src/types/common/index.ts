export const VehicleType = {
  CAR: "car",
  BUS: "bus",
  TRAM: "tram",
  BIKE: "bike",
  BOAT: "boat",
  UNKNOWN: "unknown",
} as const;
export type VehicleType = (typeof VehicleType)[keyof typeof VehicleType];

/** `upload` = session folder uploaded to S3 (main dataset), `live` = streamed through Kinesis, `replay` = re-sent by tools/replay (never aggregated). */
export const SessionSource = {
  UPLOAD: "upload",
  LIVE: "live",
  REPLAY: "replay",
} as const;
export type SessionSource = (typeof SessionSource)[keyof typeof SessionSource];

export const QualityStatus = {
  PENDING: "pending",
  OK: "ok",
  DEGRADED: "degraded",
  BAD: "bad",
} as const;
export type QualityStatus = (typeof QualityStatus)[keyof typeof QualityStatus];

export const ProcessingStatus = {
  LIVE: "live",
  PROCESSING: "processing",
  COMPLETE: "complete",
} as const;
export type ProcessingStatus = (typeof ProcessingStatus)[keyof typeof ProcessingStatus];

/** Detected road events (plan 02 §9). Rail joints are tram impacts that are not potholes (§10). */
export const RoadEventType = {
  POTHOLE: "pothole",
  SPEED_BUMP: "speed_bump",
  RAIL_JOINT: "rail_joint",
} as const;
export type RoadEventType = (typeof RoadEventType)[keyof typeof RoadEventType];

/** ISO-8601 UTC timestamp string, e.g. `2026-11-21T09:12:03.512Z`. */
export type IsoDateTime = string;

/** Unix epoch milliseconds (UTC). */
export type EpochMs = number;

export interface LngLat {
  lon: number;
  lat: number;
}
