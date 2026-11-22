import type { Feature, MultiLineString } from "geojson";
import { useEffect, useMemo, useRef, useState } from "react";

import { sessionsApi } from "@/api/sessions";
import type { HeatCollection } from "@/types/segments";
import type { SessionSummary } from "@/types/sessions";

import { REPLAY_FRAME_MS, REPLAY_LOOKAHEAD, REPLAY_MAX_STEP_MS } from "./constants";
import { playbackFrame, playbackLength, trackPlayback, type PlaybackFrame, type TrackPlayback } from "./track-playback";

interface Run {
  /** Fixed at the start, so a trip finalized meanwhile doesn't reorder the replay. */
  trips: SessionSummary[];
  index: number;
  /** Trips whose track couldn't be loaded. */
  skipped: number;
  done: Feature<MultiLineString, Record<string, never>>[];
}

export interface TripReplay {
  active: boolean;
  paused: boolean;
  /** The current trip's track hasn't arrived yet. */
  loading: boolean;
  /** Trips that can be replayed: the ones counted on the map. */
  available: number;
  trips: SessionSummary[];
  index: number;
  skipped: number;
  /** 0–1 over the whole replay. */
  progress: number;
  /** The trips already replayed, as heat lines. */
  done: HeatCollection;
  frame: PlaybackFrame | null;
  start: () => void;
  togglePause: () => void;
  stop: () => void;
}

const NO_TRIPS: SessionSummary[] = [];

/** Replays every trip counted on the map, oldest first, at `speed` times the recorded pace. */
export function useTripReplay(speed: number): TripReplay {
  const sessions = sessionsApi.useSessions();
  const [run, setRun] = useState<Run | null>(null);
  const [paused, setPaused] = useState(false);
  const [frame, setFrame] = useState<PlaybackFrame | null>(null);
  /** Playback ms into the current trip. */
  const elapsed = useRef(0);

  const available = (sessions.data ?? NO_TRIPS).filter((session) => session.includeInAgg);
  const trips = run?.trips ?? NO_TRIPS;
  const index = run?.index ?? 0;
  const tracks = sessionsApi.useSessionTracks(trips.slice(index, index + REPLAY_LOOKAHEAD));
  const current = tracks[0];
  const track = current?.data;
  const failed = current?.isError === true && !track;
  const playback = useMemo<TrackPlayback | null>(() => (track ? trackPlayback(track) : null), [track]);
  const active = run !== null;

  useEffect(() => {
    if (!active || paused || (!playback && !failed)) return;
    let handle = 0;
    let previous: number | null = null;
    let drawn = -Infinity;

    const advance = () => {
      const lines = playback && playback.points.length > 1 ? playbackFrame(playback, playbackLength(playback)).lines : [];
      elapsed.current = 0;
      setFrame(null);
      setRun((was) => {
        if (!was || was.index + 1 >= was.trips.length) return null;
        const feature = { type: "Feature" as const, geometry: { type: "MultiLineString" as const, coordinates: lines }, properties: {} };
        return {
          ...was,
          index: was.index + 1,
          skipped: was.skipped + (failed ? 1 : 0),
          done: lines.length > 0 ? [...was.done, feature] : was.done,
        };
      });
    };

    const tick = (now: number) => {
      elapsed.current += Math.min(now - (previous ?? now), REPLAY_MAX_STEP_MS) * speed;
      previous = now;
      if (!playback || playback.points.length < 2 || elapsed.current >= playbackLength(playback)) {
        advance();
        return;
      }
      if (now - drawn >= REPLAY_FRAME_MS) {
        drawn = now;
        setFrame(playbackFrame(playback, elapsed.current));
      }
      handle = requestAnimationFrame(tick);
    };
    handle = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(handle);
  }, [active, paused, index, playback, failed, speed]);

  const doneFeatures = run?.done;
  const done = useMemo<HeatCollection>(() => ({ type: "FeatureCollection", features: doneFeatures ?? [] }), [doneFeatures]);

  const reset = () => {
    elapsed.current = 0;
    setFrame(null);
    setPaused(false);
  };
  const totalS = trips.reduce((sum, trip) => sum + trip.durationS, 0);
  const tripFraction =
    frame && playback ? (frame.time - playback.times[0]) / Math.max(1, playback.times[playback.times.length - 1] - playback.times[0]) : 0;
  const playedS = trips.slice(0, index).reduce((sum, trip) => sum + trip.durationS, 0) + tripFraction * (trips[index]?.durationS ?? 0);

  return {
    active,
    paused,
    loading: active && !playback && !failed,
    available: available.length,
    trips,
    index,
    skipped: run?.skipped ?? 0,
    progress: totalS > 0 ? Math.min(1, playedS / totalS) : 0,
    done,
    frame,
    start: () => {
      if (available.length === 0) return;
      reset();
      setRun({ trips: available.sort((a, b) => a.startedAt.localeCompare(b.startedAt)), index: 0, skipped: 0, done: [] });
    },
    togglePause: () => setPaused((was) => !was),
    stop: () => {
      reset();
      setRun(null);
    },
  };
}
