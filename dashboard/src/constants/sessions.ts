import type { QualityStatus, RoadEventType, SessionSource, VehicleType } from "@/types/common";
import type { ExclusionReason } from "@/types/sessions";

export const VEHICLE_LABELS: Record<VehicleType, string> = {
  car: "Car",
  bus: "Bus",
  tram: "Tram",
  bike: "Bike",
  boat: "Boat",
  unknown: "Unknown",
};

export const SOURCE_LABELS: Record<SessionSource, string> = {
  upload: "Uploaded",
  live: "Live",
  replay: "Replay",
};

export const QUALITY_LABELS: Record<QualityStatus, string> = {
  pending: "Pending",
  ok: "Good",
  degraded: "Degraded",
  bad: "Bad",
};

export const EVENT_LABELS: Record<RoadEventType, string> = {
  pothole: "Pothole",
  speed_bump: "Speed bump",
  rail_joint: "Rail joint",
};

export const EXCLUSION_LABELS: Record<ExclusionReason, string> = {
  replay: "Replay — never aggregated",
  live_only: "Live only — aggregated once the session folder is uploaded",
  bad_quality: "Bad data quality",
  not_rigid: "Mount not rigid — no roughness, sickness experimental",
  handheld: "Hand-held — no roughness, sickness experimental",
  processing: "Still processing",
};

export const STREAM_LABELS: Record<string, string> = {
  device_motion: "Device motion",
  accel_raw: "Accelerometer (raw)",
  gyro_raw: "Gyroscope (raw)",
  mag_raw: "Magnetometer",
  location: "GPS",
  altimeter: "Barometer",
  audio_level: "Audio level",
  device: "Device health",
};

/** Measured rate below this share of the expected rate is flagged (spec §7: < 90 Hz of 100 Hz). */
export const STREAM_RATE_WARN_RATIO = 0.9;
/** Gaps longer than 1 s are listed in red (spec §7, session summary). */
export const STREAM_GAP_PROBLEM_S = 1;
