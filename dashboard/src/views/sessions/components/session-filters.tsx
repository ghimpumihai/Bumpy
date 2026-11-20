import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { SOURCE_LABELS, VEHICLE_LABELS } from "@/constants/sessions";
import { SessionSource, VehicleType } from "@/types/common";

import { ANY_FILTER, type SessionsSearch } from "../schema";

interface SessionFiltersProps {
  search: SessionsSearch;
  onChange: (patch: Partial<SessionsSearch>) => void;
}

export function SessionFilters({ search, onChange }: SessionFiltersProps) {
  return (
    <div className="flex flex-wrap items-end gap-3">
      <div className="vertical gap-1">
        <Label htmlFor="filter-source" className="text-xs text-muted-foreground">
          Source
        </Label>
        <Select value={search.source} onValueChange={(value) => onChange({ source: value as SessionsSearch["source"] })}>
          <SelectTrigger id="filter-source" className="w-40">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ANY_FILTER}>All sources</SelectItem>
            {Object.values(SessionSource).map((source) => (
              <SelectItem key={source} value={source}>
                {SOURCE_LABELS[source]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="vertical gap-1">
        <Label htmlFor="filter-vehicle" className="text-xs text-muted-foreground">
          Vehicle
        </Label>
        <Select value={search.vehicle} onValueChange={(value) => onChange({ vehicle: value as SessionsSearch["vehicle"] })}>
          <SelectTrigger id="filter-vehicle" className="w-40">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ANY_FILTER}>All vehicles</SelectItem>
            {Object.values(VehicleType).map((vehicle) => (
              <SelectItem key={vehicle} value={vehicle}>
                {VEHICLE_LABELS[vehicle]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
    </div>
  );
}
