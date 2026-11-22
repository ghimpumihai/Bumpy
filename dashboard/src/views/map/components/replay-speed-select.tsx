import { useNavigate, useSearch } from "@tanstack/react-router";
import { memo } from "react";

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

import type { MapSearch } from "../schema";
import { REPLAY_SPEEDS } from "../utils/constants";

/** Memoized: the replay re-renders its parent on every frame, and each render moves the open menu's focus back to the current speed. */
export const ReplaySpeedSelect = memo(function ReplaySpeedSelect() {
  const speed = useSearch({ from: "/map", select: (search) => search.speed });
  const navigate = useNavigate({ from: "/map" });
  return (
    <Select
      value={String(speed)}
      onValueChange={(value) => void navigate({ search: (prev) => ({ ...prev, speed: Number(value) as MapSearch["speed"] }), replace: true })}
    >
      <SelectTrigger size="sm" aria-label="Replay speed" className="gap-1 pr-1 pl-2 text-xs tabular-nums">
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {REPLAY_SPEEDS.map((option) => (
          <SelectItem key={option} value={String(option)} className="text-xs tabular-nums">
            {option}×
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
});
