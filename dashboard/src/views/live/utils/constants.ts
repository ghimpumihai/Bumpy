import { MS_PER_SECOND } from "@/constants/units";

export const LIVE_TRACKS_SOURCE_ID = "live-tracks";
export const LIVE_DEVICES_SOURCE_ID = "live-devices";
export const LIVE_MARKER_RADIUS_PX = 8;
export const LIVE_TRACK_WIDTH_PX = 4;

/** No new batch for this long: the phone is probably in a tunnel or offline. */
export const LIVE_STALE_WARN_MS = 10 * MS_PER_SECOND;
export const LIVE_STALE_PROBLEM_MS = 30 * MS_PER_SECOND;
