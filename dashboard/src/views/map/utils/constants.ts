export const SEGMENTS_SOURCE_ID = "segments";
export const SEGMENT_HIT_LAYER_ID = "segments-hit";
export const SELECTED_SEGMENT_LAYER_ID = "segments-selected";
export const EVENTS_SOURCE_ID = "events";

export const SEGMENT_HIT_RADIUS_PX = 12;
export const SELECTED_OUTLINE_WIDTH_PX = 2.5;

export const SEGMENT_INTERACTIVE_LAYERS = [SEGMENT_HIT_LAYER_ID];
/** Entries in the keyboard-accessible list of busiest segments. */
export const HIGHLIGHT_COUNT = 8;

export const REPLAY_SOURCE_ID = "replay";
export const REPLAY_GLOW_LAYER_ID = `${REPLAY_SOURCE_ID}-glow`;
export const REPLAY_LINE_LAYER_ID = `${REPLAY_SOURCE_ID}-line`;
/** Multiples of the recorded pace. */
export const REPLAY_SPEEDS = [30, 60, 120, 300, 600, 1200] as const;
export const DEFAULT_REPLAY_SPEED = 60;
/** The map redraws the trip in progress at most this often: its line goes through MapLibre's worker. */
export const REPLAY_FRAME_MS = 40;
/** Longest step of the replay clock, so a stalled frame or a hidden tab doesn't skip ahead. */
export const REPLAY_MAX_STEP_MS = 100;
/** Tracks fetched at a time: the trip being replayed and the next ones. */
export const REPLAY_LOOKAHEAD = 3;
/** Where the track is cut, as the read API cuts the heat lines (HEAT_GAP_S, HEAT_GAP_DEG); a longer silence is shortened to this. */
export const REPLAY_GAP_MS = 10_000;
export const REPLAY_GAP_DEG = 0.002;
