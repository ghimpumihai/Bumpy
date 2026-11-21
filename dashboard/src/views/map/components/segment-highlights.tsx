import { ChevronUp } from "lucide-react";

import type { SegmentCollection } from "@/types/segments";

import { HIGHLIGHT_COUNT } from "../utils/constants";
import { busiestSegments, heatColor } from "../utils/highlights";

interface SegmentHighlightsProps {
  data: SegmentCollection;
  selectedH3: string | undefined;
  onSelect: (h3: string) => void;
}

/** Keyboard-reachable entry to the busiest roads (the map itself can only be clicked): a pill that opens a short list upward. */
export function SegmentHighlights({ data, selectedH3, onSelect }: SegmentHighlightsProps) {
  const segments = busiestSegments(data, HIGHLIGHT_COUNT);
  if (segments.length === 0) return null;
  return (
    <details className="group relative text-xs">
      <summary className="horizontal cursor-pointer list-none gap-1.5 rounded-full border border-white/10 bg-card/70 px-3 py-1.5 font-medium shadow-lg backdrop-blur-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring [&::-webkit-details-marker]:hidden">
        Busiest roads
        <ChevronUp className="size-3.5 text-muted-foreground transition-transform group-open:rotate-180" aria-hidden="true" />
      </summary>
      <ol className="absolute right-0 bottom-full mb-2 w-52 rounded-2xl border border-white/10 bg-card/85 p-1 shadow-lg backdrop-blur-md" aria-label="Busiest roads">
        {segments.map((segment, index) => (
          <li key={segment.h3}>
            <button
              type="button"
              onClick={() => onSelect(segment.h3)}
              aria-current={segment.h3 === selectedH3 ? "true" : undefined}
              className="horizontal w-full justify-between gap-3 rounded-xl px-2.5 py-1 text-left hover:bg-background-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring aria-[current=true]:bg-muted"
            >
              <span className="horizontal gap-2">
                <span className="w-3 text-[11px] text-muted-foreground tabular-nums">{index + 1}</span>
                <span className="size-2 rounded-full" style={{ background: heatColor(segment.nSessions) }} aria-hidden="true" />
              </span>
              <span className="font-medium tabular-nums">
                {segment.nSessions} {segment.nSessions === 1 ? "trip" : "trips"}
              </span>
            </button>
          </li>
        ))}
      </ol>
    </details>
  );
}
