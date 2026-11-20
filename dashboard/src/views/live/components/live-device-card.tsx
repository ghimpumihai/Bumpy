import { Link } from "@tanstack/react-router";
import { BatteryMedium, Thermometer } from "lucide-react";

import { SourceBadge } from "@/components/status/session-badges";
import { VehicleLabel } from "@/components/status/vehicle-label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import type { LiveDevice } from "@/types/live";
import { StreamStatus } from "@/types/sessions";
import { formatAge } from "@/utils/format-date-time";
import { formatAcceleration, formatFraction, formatMsdv, formatSpeedFromMs } from "@/utils/format-number";

import { LIVE_STALE_PROBLEM_MS, LIVE_STALE_WARN_MS } from "../utils/constants";

const FRESHNESS_BADGE: Record<StreamStatus, "success" | "warning" | "destructive"> = {
  [StreamStatus.OK]: "success",
  [StreamStatus.WARN]: "warning",
  [StreamStatus.PROBLEM]: "destructive",
};

interface LiveDeviceCardProps {
  device: LiveDevice;
  /** Current time on the server's clock (so a wrong laptop clock can't make data look stale). */
  now: number;
}

export function LiveDeviceCard({ device, now }: LiveDeviceCardProps) {
  const ageMs = now - Date.parse(device.updatedAt);
  const freshness: StreamStatus =
    ageMs > LIVE_STALE_PROBLEM_MS ? StreamStatus.PROBLEM : ageMs > LIVE_STALE_WARN_MS ? StreamStatus.WARN : StreamStatus.OK;
  const metrics = [
    { label: "Speed", value: formatSpeedFromMs(device.speedMs) },
    { label: "Roughness now", value: formatAcceleration(device.roughnessNow) },
    { label: "MSDV so far", value: formatMsdv(device.msdvSoFar) },
  ];
  return (
    <Card className="py-0">
      <CardContent className="vertical gap-3 p-4">
        <div className="horizontal justify-between gap-2">
          <VehicleLabel type={device.vehicleType} className="font-medium" />
          <SourceBadge source={device.source} />
        </div>
        <dl className="grid grid-cols-3 gap-2">
          {metrics.map((metric) => (
            <div key={metric.label} className="vertical">
              <dt className="text-[11px] text-muted-foreground">{metric.label}</dt>
              <dd className="text-sm font-semibold tabular-nums">{metric.value}</dd>
            </div>
          ))}
        </dl>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
          <span className="horizontal gap-1">
            <Badge variant={FRESHNESS_BADGE[freshness]}>
              updated {formatAge(device.updatedAt, now)}
            </Badge>
          </span>
          <span className="horizontal gap-1">
            <BatteryMedium className="size-3.5" aria-hidden="true" />
            {formatFraction(device.battery)}
          </span>
          {device.thermal && (
            <span className="horizontal gap-1">
              <Thermometer className="size-3.5" aria-hidden="true" />
              {device.thermal}
            </span>
          )}
          <Link to="/sessions/$sessionId" params={{ sessionId: device.sessionId }} className="ml-auto text-accent underline-offset-4 hover:underline">
            Session details
          </Link>
        </div>
      </CardContent>
    </Card>
  );
}
