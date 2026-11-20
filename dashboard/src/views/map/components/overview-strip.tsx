import { overviewApi } from "@/api/overview";
import { Skeleton } from "@/components/ui/skeleton";
import { formatDateTime } from "@/utils/format-date-time";
import { formatNumber } from "@/utils/format-number";

/** Headline numbers of the aggregated dataset. */
export function OverviewStrip() {
  const { data, isPending, error } = overviewApi.useOverview();
  if (error) return null;
  if (isPending) return <Skeleton className="h-14 w-72" />;
  const items = [
    { label: "Sessions on the map", value: `${data.sessions.includedInAgg} / ${data.sessions.total}` },
    { label: "Distance", value: `${formatNumber(data.distanceKm, 1)} km` },
    { label: "Road segments", value: formatNumber(data.segments) },
    { label: "Confirmed potholes", value: formatNumber(data.confirmedPotholes) },
  ];
  return (
    <section aria-label="Dataset overview" className="vertical gap-1 rounded-lg border bg-card/95 p-3 shadow-sm">
      <dl className="grid grid-cols-2 gap-x-5 gap-y-1 sm:grid-cols-4">
        {items.map((item) => (
          <div key={item.label} className="vertical">
            <dt className="text-[11px] text-muted-foreground">{item.label}</dt>
            <dd className="text-base font-semibold tabular-nums text-foreground">{item.value}</dd>
          </div>
        ))}
      </dl>
      <p className="text-[11px] text-muted-foreground">Last processed {formatDateTime(data.lastProcessedAt)}</p>
    </section>
  );
}
