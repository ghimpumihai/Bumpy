import { Link } from "@tanstack/react-router";
import { BatteryMedium, Crosshair, Thermometer } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { PLACEHOLDER } from "@/constants";
import { MISC_MAX, VEHICLE_LABELS } from "@/constants/sessions";
import type { LiveDevice } from "@/types/live";
import { StreamStatus } from "@/types/sessions";
import { formatTime } from "@/utils/format-date-time";
import { formatAcceleration, formatFraction, formatMsdv, formatNumber, formatSpeedFromMs } from "@/utils/format-number";

import { freshnessLabel, liveFreshness } from "../utils/freshness";

const FRESHNESS_BADGE: Record<StreamStatus, "success" | "warning" | "destructive"> = {
  [StreamStatus.OK]: "success",
  [StreamStatus.WARN]: "warning",
  [StreamStatus.PROBLEM]: "destructive",
};

interface LiveDeviceCardProps {
  device: LiveDevice;
  /** Current time on the server's clock (so a wrong laptop clock can't make data look stale). */
  now: number;
  /** The dashboard lost the read API: show when the data is from, without judging the phone. */
  apiUnreachable: boolean;
  /** Fly the map to this vehicle. */
  onLocate: () => void;
}

export function LiveDeviceCard({ device, now, apiUnreachable, onLocate }: LiveDeviceCardProps) {
  const freshness = liveFreshness(device, now);
  const metrics = [
    { label: "Speed", value: formatSpeedFromMs(device.speedMs) },
    { label: "Roughness now", value: formatAcceleration(device.roughnessNow) },
    { label: "MSDV so far", value: formatMsdv(device.msdvSoFar) },
    {
      label: "Latest MISC",
      value: device.latestRating ? `${formatNumber(device.latestRating.value)} / ${MISC_MAX}` : PLACEHOLDER,
      hint: device.latestRating ? `at ${formatTime(device.latestRating.tUtc)}` : "no rating yet",
    },
  ];
  const freshnessText = freshnessLabel(device, freshness, apiUnreachable);
  return (
    <Card className="py-0">
      <CardContent className="vertical gap-3 p-4">
        <div className="vertical gap-0.5">
          <span className="text-sm font-medium">
            {VEHICLE_LABELS[device.vehicleType]} · iPhone {device.deviceId.slice(0, 8)}
          </span>
          <span className="text-xs text-muted-foreground">
            {device.source === "replay" ? "Replay" : "Streaming"} · last update {formatTime(device.updatedAt)}
          </span>
        </div>
        <dl className="grid grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-4 lg:grid-cols-2">
          {metrics.map((metric) => (
            <div key={metric.label} className="vertical">
              <dt className="text-[11px] text-muted-foreground">{metric.label}</dt>
              <dd className="text-sm font-semibold tabular-nums">{metric.value}</dd>
              {metric.hint && <dd className="text-[11px] text-muted-foreground">{metric.hint}</dd>}
            </div>
          ))}
        </dl>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
          <Badge
            variant={apiUnreachable || freshness.ended ? "secondary" : FRESHNESS_BADGE[freshness.status]}
            title="End-to-end delay: phone → ingest → stream → processor → this screen"
          >
            {freshnessText}
          </Badge>
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
          <button
            type="button"
            onClick={onLocate}
            aria-label="Show on map"
            className="ml-auto rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <Crosshair className="size-4" aria-hidden="true" />
          </button>
          <Link to="/sessions/$sessionId" params={{ sessionId: device.sessionId }} className="text-accent underline-offset-4 hover:underline">
            Session details
          </Link>
        </div>
      </CardContent>
    </Card>
  );
}
