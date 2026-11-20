import { CircleAlert } from "lucide-react";

import type { MetricScale } from "@/types/map";
import type { SegmentAggregate, SegmentCollection } from "@/types/segments";
import { formatAcceleration, formatFraction, formatPercent } from "@/utils/format-number";

import { HIGHLIGHT_COUNT } from "../utils/constants";
import { worstSegments } from "../utils/highlights";

interface SegmentHighlightsProps {
  data: SegmentCollection;
  scale: MetricScale;
  selectedH3: string | undefined;
  onSelect: (h3: string) => void;
}

function metricText(segment: SegmentAggregate, scale: MetricScale): string {
  if (scale.property === "msi1hPct") return `${formatPercent(segment.msi1hPct)} / h`;
  if (scale.property === "roughnessPctl") return `${formatFraction(segment.roughnessPctl)} pctl`;
  return formatAcceleration(segment.roughness);
}

/** Keyboard-reachable entry to the worst segments (the map itself can only be clicked). */
export function SegmentHighlights({ data, scale, selectedH3, onSelect }: SegmentHighlightsProps) {
  const segments = worstSegments(data, scale, HIGHLIGHT_COUNT);
  if (segments.length === 0) return null;
  return (
    <details className="group rounded-lg border bg-card/95 text-sm shadow-sm">
      <summary className="cursor-pointer rounded-lg px-3 py-2 font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
        Worst segments
      </summary>
      <ol className="vertical gap-0.5 px-1.5 pb-2" aria-label={`Worst segments by ${scale.title.toLowerCase()}`}>
        {segments.map((segment, index) => (
          <li key={segment.h3}>
            <button
              type="button"
              onClick={() => onSelect(segment.h3)}
              aria-current={segment.h3 === selectedH3 ? "true" : undefined}
              className="horizontal w-full justify-between gap-3 rounded-md px-2 py-1 text-left hover:bg-background-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring aria-[current=true]:bg-muted"
            >
              <span className="horizontal gap-1.5">
                <span className="w-4 text-xs text-muted-foreground tabular-nums">{index + 1}</span>
                {segment.potholeConfirmed && <CircleAlert className="size-3.5 text-destructive" aria-label="confirmed pothole" />}
                <span className="text-xs text-muted-foreground">
                  {segment.nSessions} {segment.nSessions === 1 ? "trip" : "trips"}
                </span>
              </span>
              <span className="font-medium tabular-nums">{metricText(segment, scale)}</span>
            </button>
          </li>
        ))}
      </ol>
    </details>
  );
}
