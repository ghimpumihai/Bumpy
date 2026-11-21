import type { ProcessingStatus, QualityStatus, RoadEventType, SessionSource, VehicleType } from "@/types/common";
import type { ExclusionReason } from "@/types/sessions";

export const VEHICLE_LABELS: Record<VehicleType, string> = {
  car: "Car",
  bus: "Bus",
  tram: "Tram",
  bike: "Bike",
  boat: "Boat",
  unknown: "Unknown",
};

/** How the trip reached the cloud. Streaming is the normal path, so it is labelled plainly. */
export const SOURCE_LABELS: Record<SessionSource, string> = {
  live: "Streamed",
  upload: "Uploaded",
  replay: "Replay",
};

export const SOURCE_DESCRIPTIONS: Record<SessionSource, string> = {
  live: "Sent by the phone while driving (the main path)",
  upload: "Session folder uploaded from a laptop (fallback: the trip never reached the cloud)",
  replay: "A recorded trip re-sent through the live path; never counted in the map",
};

export const STATUS_LABELS: Record<ProcessingStatus, string> = {
  live: "Recording",
  processing: "Processing",
  complete: "Finalized",
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
  live_only: "Not finalized yet — counts once the finalize job has processed the whole trip",
  processing: "Upload still being processed",
  bad_quality: "Bad data quality",
  unknown_context: "Context unknown (session.json never arrived) — can't be compared with other trips",
  not_rigid: "Mount not rigid — no roughness, sickness experimental",
  handheld: "Hand-held — no roughness, sickness experimental",
};

export const INCOMPLETE_DESCRIPTION =
  "Closed without the app's Stop message (15 minutes without data); gaps are marked and the rest still counts.";

export const STREAM_LABELS: Record<string, string> = {
  device_motion: "Device motion",
  accel_raw: "Accelerometer (raw)",
  gyro_raw: "Gyroscope (raw)",
  mag_raw: "Magnetometer",
  location: "GPS",
  altimeter: "Barometer",
  device: "Device health",
};

/** Top of the MISC motion-sickness scale (0 = no problems … 10 = vomiting). */
export const MISC_MAX = 10;

/** Measured rate below this share of the expected rate is flagged (spec §7: < 90 Hz of 100 Hz). */
export const STREAM_RATE_WARN_RATIO = 0.9;
/** Gaps longer than 1 s are listed in red (spec §7, session summary)… */
export const STREAM_GAP_PROBLEM_S = 1;
/** …but a slow stream (1 Hz GPS, 0.2 Hz device health) only has a gap once this many samples are missing. */
export const STREAM_GAP_MISSED_SAMPLES = 3;
