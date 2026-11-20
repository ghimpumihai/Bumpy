import { MS_PER_SECOND } from "@/constants/units";

export const LIVE_TRACKS_SOURCE_ID = "live-tracks";
export const LIVE_DEVICES_SOURCE_ID = "live-devices";
export const LIVE_MARKER_RADIUS_PX = 8;
export const LIVE_TRACK_WIDTH_PX = 4;
export const LIVE_TRACK_OPACITY = 0.7;
export const LIVE_HALO_SCALE = 2;
export const LIVE_HALO_OPACITY = 0.18;
export const LIVE_MARKER_STROKE_PX = 2;
export const CARD_ANIMATION_S = 0.2;
export const CARD_ANIMATION_OFFSET_PX = 8;

/** No new batch for this long: the phone is probably in a tunnel or offline. */
export const LIVE_STALE_WARN_MS = 10 * MS_PER_SECOND;
export const LIVE_STALE_PROBLEM_MS = 30 * MS_PER_SECOND;
/** End-to-end target is under 10 s (plan 02 §5); beyond that the phone is sending a backlog after a dead zone. */
export const LIVE_CATCHING_UP_MS = 10 * MS_PER_SECOND;
