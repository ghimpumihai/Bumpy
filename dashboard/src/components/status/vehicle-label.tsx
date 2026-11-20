import { Bike, Bus, Car, CircleHelp, Sailboat, TramFront, type LucideIcon } from "lucide-react";

import { VEHICLE_LABELS } from "@/constants/sessions";
import { cn } from "@/lib/utils";
import type { VehicleType } from "@/types/common";

const VEHICLE_ICONS: Record<VehicleType, LucideIcon> = {
  car: Car,
  bus: Bus,
  tram: TramFront,
  bike: Bike,
  boat: Sailboat,
  unknown: CircleHelp,
};

interface VehicleLabelProps {
  type: VehicleType;
  line?: string | null;
  detail?: string;
  className?: string;
}

export function VehicleLabel({ type, line, detail, className }: VehicleLabelProps) {
  const Icon = VEHICLE_ICONS[type];
  return (
    <span className={cn("horizontal gap-1.5", className)}>
      <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
      <span>
        {VEHICLE_LABELS[type]}
        {line && ` ${line}`}
        {detail && <span className="text-muted-foreground"> · {detail}</span>}
      </span>
    </span>
  );
}
