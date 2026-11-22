import { Pause, Play, Square } from "lucide-react";

import { Button } from "@/components/ui/button";
import { formatDateTime } from "@/utils/format-date-time";

import type { TripReplay } from "../utils/use-trip-replay";
import { ReplaySpeedSelect } from "./replay-speed-select";

interface TripReplayControlsProps {
  replay: TripReplay;
  disabled: boolean;
}

/** Plays every trip on the map one after the other, so the heat map builds up. */
export function TripReplayControls({ replay, disabled }: TripReplayControlsProps) {
  const trip = replay.trips[replay.index];
  return (
    <div className="vertical gap-2 border-t border-white/10 pt-2">
      <div className="horizontal justify-between gap-1">
        {replay.active ? (
          <div className="horizontal gap-1">
            <Button size="icon-sm" variant="secondary" aria-label={replay.paused ? "Resume replay" : "Pause replay"} onClick={replay.togglePause}>
              {replay.paused ? <Play /> : <Pause />}
            </Button>
            <Button size="icon-sm" variant="ghost" aria-label="Stop replay" onClick={replay.stop}>
              <Square />
            </Button>
          </div>
        ) : (
          <Button size="xs" variant="secondary" leftIcon={<Play />} disabled={disabled || replay.available === 0} onClick={replay.start} className="h-7">
            Replay
          </Button>
        )}
        <ReplaySpeedSelect />
      </div>
      {replay.active && trip && (
        <div className="vertical gap-1 text-[11px] text-muted-foreground tabular-nums">
          <div
            role="progressbar"
            aria-label="Replay progress"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(replay.progress * 100)}
            className="h-1 overflow-hidden rounded-full bg-muted"
          >
            <div className="h-full bg-heat-low" style={{ width: `${replay.progress * 100}%` }} />
          </div>
          <span>
            Trip {replay.index + 1} / {replay.trips.length}
            {replay.loading && " · loading"}
          </span>
          <span>{formatDateTime(trip.startedAt)}</span>
          {replay.skipped > 0 && <span>{replay.skipped} skipped: couldn’t load</span>}
        </div>
      )}
    </div>
  );
}
