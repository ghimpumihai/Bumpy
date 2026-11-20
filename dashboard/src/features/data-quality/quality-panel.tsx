import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import type { SessionQuality } from "@/types/sessions";
import { formatDuration } from "@/utils/format-date-time";
import { formatFraction, formatMeters, formatNumber } from "@/utils/format-number";

import { StreamQualityTable } from "./stream-quality-table";

const INVALID_LABELS: Record<keyof SessionQuality["invalidSeconds"], string> = {
  phone_moved: "Phone moved (tapped)",
  gravity_drift: "Gravity drifted in phone frame",
  gyro_gps_mismatch: "Gyro turn rate ≠ GPS course",
  gps_poor: "GPS accuracy too low",
};

/** The data-quality panel of plan 02 §10: sample rates, gaps, GPS accuracy, valid fraction, rejected batches. */
export function QualityPanel({ quality }: { quality: SessionQuality }) {
  const facts = [
    { label: "Valid data", value: formatFraction(quality.validFraction) },
    { label: "GPS fixes", value: formatNumber(quality.gps.fixes) },
    { label: "GPS accuracy (median / p95)", value: `${formatMeters(quality.gps.medianHAccM)} / ${formatMeters(quality.gps.p95HAccM)}` },
    { label: "Rejected live batches", value: formatNumber(quality.rejectedBatches) },
    { label: "Late / duplicate batches", value: `${formatNumber(quality.lateBatches)} / ${formatNumber(quality.duplicateBatches)}` },
  ];
  return (
    <Card>
      <CardHeader>
        <CardTitle>Data quality</CardTitle>
        <CardDescription>Measured on the trip's data (finalized from the full archive); windows that fail a check are left out of roughness and potholes.</CardDescription>
      </CardHeader>
      <CardContent className="vertical gap-4">
        <dl className="grid grid-cols-2 gap-3 sm:grid-cols-5">
          {facts.map((fact) => (
            <div key={fact.label} className="vertical gap-0.5">
              <dt className="text-xs text-muted-foreground">{fact.label}</dt>
              <dd className="text-sm font-medium tabular-nums">{fact.value}</dd>
            </div>
          ))}
        </dl>
        <StreamQualityTable streams={quality.streams} />
        <div className="vertical gap-1">
          <h3 className="text-sm font-medium">Invalid windows</h3>
          <ul className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
            {Object.entries(quality.invalidSeconds).map(([reason, seconds]) => (
              <li key={reason} className="horizontal justify-between gap-2 rounded-md bg-muted px-2 py-1">
                <span className="text-muted-foreground">{INVALID_LABELS[reason as keyof SessionQuality["invalidSeconds"]]}</span>
                <span className="tabular-nums">{formatDuration(seconds)}</span>
              </li>
            ))}
          </ul>
        </div>
      </CardContent>
    </Card>
  );
}
