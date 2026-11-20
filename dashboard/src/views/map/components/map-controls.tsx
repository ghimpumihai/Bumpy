import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { METRIC_LABELS } from "@/constants/map";
import { MapMetric } from "@/types/map";
import { VehicleFilter } from "@/types/segments";

import type { MapSearch } from "../schema";

const VEHICLE_FILTER_LABELS: Record<VehicleFilter, string> = {
  all: "All vehicles",
  car: "Cars",
  bus: "Buses",
  tram: "Trams",
};

interface MapControlsProps {
  search: MapSearch;
  onChange: (patch: Partial<MapSearch>) => void;
}

const isMetric = (value: string): value is MapMetric => (Object.values(MapMetric) as string[]).includes(value);
const isVehicleFilter = (value: string): value is VehicleFilter => (Object.values(VehicleFilter) as string[]).includes(value);

export function MapControls({ search, onChange }: MapControlsProps) {
  return (
    <section aria-label="Map layers" className="vertical gap-3 rounded-lg border bg-card/95 p-3 shadow-sm">
      <ToggleGroup
        type="single"
        variant="outline"
        size="sm"
        value={search.metric}
        onValueChange={(value) => isMetric(value) && onChange({ metric: value })}
        aria-label="Colour hexagons by"
      >
        {Object.values(MapMetric).map((metric) => (
          <ToggleGroupItem key={metric} value={metric} className="px-3">
            {METRIC_LABELS[metric]}
          </ToggleGroupItem>
        ))}
      </ToggleGroup>
      <div className="horizontal justify-between gap-3">
        <Label htmlFor="vehicle-filter" className="text-xs text-muted-foreground">
          Vehicle
        </Label>
        <Select value={search.vehicle} onValueChange={(value) => isVehicleFilter(value) && onChange({ vehicle: value })}>
          <SelectTrigger id="vehicle-filter" size="sm" className="w-40">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {Object.values(VehicleFilter).map((vehicle) => (
              <SelectItem key={vehicle} value={vehicle}>
                {VEHICLE_FILTER_LABELS[vehicle]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="horizontal justify-between gap-3">
        <Label htmlFor="events-toggle" className="text-xs text-muted-foreground">
          Detected events
        </Label>
        <Switch id="events-toggle" checked={search.events} onCheckedChange={(checked) => onChange({ events: checked })} />
      </div>
    </section>
  );
}
