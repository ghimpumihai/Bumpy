import { cn } from "@/lib/utils";
import type { ScaleBand } from "@/types/map";

interface MapLegendProps {
  title: string;
  bands: ScaleBand[];
  /** Label for features without a value. */
  missingLabel?: string;
  footnote?: string;
  className?: string;
}

/** Colour key of a map layer; swatches use the same CSS tokens as the map paint. */
export function MapLegend({ title, bands, missingLabel, footnote, className }: MapLegendProps) {
  return (
    <section aria-label={`${title} legend`} className={cn("vertical gap-1.5 rounded-lg border bg-card/95 p-3 text-xs shadow-sm", className)}>
      <h2 className="font-medium text-foreground">{title}</h2>
      <ul className="vertical gap-1">
        {bands.map((band) => (
          <li key={band.label} className="horizontal gap-2 text-muted-foreground">
            {/* Swatch colour comes from a runtime CSS variable. */}
            <span className="size-3 shrink-0 rounded-sm border border-border" style={{ background: `var(${band.colorVar})` }} aria-hidden="true" />
            {band.label}
          </li>
        ))}
        {missingLabel && (
          <li className="horizontal gap-2 text-muted-foreground">
            <span className="size-3 shrink-0 rounded-sm border border-border bg-scale-none" aria-hidden="true" />
            {missingLabel}
          </li>
        )}
      </ul>
      {footnote && <p className="hidden max-w-56 text-[11px] text-muted-foreground sm:block">{footnote}</p>}
    </section>
  );
}
