import { MS_PER_SECOND } from "@/constants/units";

export const LIVE_TRACKS_SOURCE_ID = "live-tracks";
export const LIVE_TRACK_WIDTH_PX = 2.5;
export const LIVE_TRACK_GLOW_PX = 9;
/** Marker animation: ~30 fps is smooth enough and the map re-renders on every frame. */
export const LIVE_FRAME_MS = 33;
/** How often the trail's geometry is refreshed while the marker glides. */
export const LIVE_TRAIL_MS = 100;
export const CARD_ANIMATION_S = 0.2;
export const CARD_ANIMATION_OFFSET_PX = 8;

/** No new batch for this long: the phone is probably in a tunnel or offline. */
export const LIVE_STALE_WARN_MS = 10 * MS_PER_SECOND;
export const LIVE_STALE_PROBLEM_MS = 30 * MS_PER_SECOND;
/** End-to-end target is under 10 s (plan 02 §5); beyond that the phone is sending a backlog after a dead zone. */
export const LIVE_CATCHING_UP_MS = 10 * MS_PER_SECOND;

/** A detection ping: one thin ring that grows this far and fades, once. */
export const LIVE_PING_MS = 1300;
export const LIVE_PING_GROWTH_PX = 28;
/** The camera glide to a vehicle picked from its card. */
export const LIVE_FOCUS_ZOOM = 15.5;
export const LIVE_FOCUS_MS = 1300;
