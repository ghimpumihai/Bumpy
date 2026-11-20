import { Link } from "@tanstack/react-router";
import { BatteryMedium, Thermometer } from "lucide-react";

import { SourceBadge } from "@/components/status/session-badges";
import { VehicleLabel } from "@/components/status/vehicle-label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { PLACEHOLDER } from "@/constants";
import { MS_PER_SECOND } from "@/constants/units";
import type { LiveDevice } from "@/types/live";
import { StreamStatus } from "@/types/sessions";
import { formatTime } from "@/utils/format-date-time";
import { formatAcceleration, formatFraction, formatMsdv, formatNumber, formatSeconds, formatSpeedFromMs } from "@/utils/format-number";

import { liveFreshness } from "../utils/freshness";

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

const seconds = (ms: number) => ms / MS_PER_SECOND;

export function LiveDeviceCard({ device, now }: LiveDeviceCardProps) {
  const freshness = liveFreshness(device, now);
  const metrics = [
    { label: "Speed", value: formatSpeedFromMs(device.speedMs) },
    { label: "Roughness now", value: formatAcceleration(device.roughnessNow) },
    { label: "MSDV so far", value: formatMsdv(device.msdvSoFar) },
    {
      label: "Latest MISC",
      value: device.latestRating ? `${device.latestRating.value} / 10` : PLACEHOLDER,
      hint: device.latestRating ? `at ${formatTime(device.latestRating.tUtc)}` : "no rating yet",
    },
  ];
  const freshnessText = freshness.catchingUp
    ? `catching up · ${formatNumber(seconds(freshness.transportDelayMs))} s behind`
    : freshness.status === StreamStatus.OK
      ? `${formatSeconds(seconds(freshness.dataAgeMs), 1)} behind the phone`
      : `no data for ${formatNumber(seconds(freshness.silentForMs))} s`;
  return (
    <Card className="py-0">
      <CardContent className="vertical gap-3 p-4">
        <div className="horizontal justify-between gap-2">
          <VehicleLabel type={device.vehicleType} className="font-medium" />
          <SourceBadge source={device.source} />
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
          <Badge variant={FRESHNESS_BADGE[freshness.status]} title="End-to-end delay: phone → ingest → stream → processor → this screen">
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
          <Link to="/sessions/$sessionId" params={{ sessionId: device.sessionId }} className="ml-auto text-accent underline-offset-4 hover:underline">
            Session details
          </Link>
        </div>
      </CardContent>
    </Card>
  );
}
