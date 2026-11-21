import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";

const EVENT_KEY = [
  { label: "Pothole", className: "bg-event-pothole" },
  { label: "Speed bump", className: "bg-event-speed-bump" },
  { label: "Rail joint", className: "bg-event-rail-joint" },
];

interface HeatLegendProps {
  className?: string;
  showEvents: boolean;
  onShowEventsChange: (show: boolean) => void;
}

/** One quiet card: what the colour means, and the switch for the detected-event dots. */
export function HeatLegend({ className, showEvents, onShowEventsChange }: HeatLegendProps) {
  return (
    <section aria-label="Map legend" className={cn("vertical w-40 gap-2 rounded-2xl border border-white/10 bg-card/70 p-3 text-xs shadow-lg backdrop-blur-md", className)}>
      <div className="vertical gap-1.5">
        <h2 className="font-medium text-foreground">Trips per road</h2>
        <div className="h-2 rounded-full" style={{ background: "linear-gradient(to right, var(--heat-low), var(--heat-mid), var(--heat))" }} aria-hidden="true" />
        <div className="horizontal justify-between text-[11px] text-muted-foreground">
          <span>1</span>
          <span>12+</span>
        </div>
      </div>
      <div className="horizontal justify-between gap-2 border-t border-white/10 pt-2">
        <Label htmlFor="events-toggle" className="text-xs font-medium text-foreground">
          Detected events
        </Label>
        <Switch id="events-toggle" className="scale-75" checked={showEvents} onCheckedChange={onShowEventsChange} />
      </div>
      {showEvents && (
        <ul className="vertical gap-1">
          {EVENT_KEY.map((event) => (
            <li key={event.label} className="horizontal gap-2 text-[11px] text-muted-foreground">
              <span className={`size-2 shrink-0 rounded-full ${event.className}`} aria-hidden="true" />
              {event.label}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
