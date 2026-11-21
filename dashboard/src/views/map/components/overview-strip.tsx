import { overviewApi } from "@/api/overview";
import { sessionsApi } from "@/api/sessions";
import { ErrorAlert } from "@/components/error-alert";
import { Skeleton } from "@/components/ui/skeleton";
import { METERS_PER_KM } from "@/constants/units";
import { formatDateTime } from "@/utils/format-date-time";
import { formatDistance, formatNumber, formatPercent } from "@/utils/format-number";

/** Headline numbers of the aggregated dataset. */
export function OverviewStrip({ stacked = false }: { stacked?: boolean }) {
  const { data, isPending, error, refetch } = overviewApi.useOverview();
  const sessions = sessionsApi.useSessions();
  // Time-weighted average over the trips that count on the map.
  const counted = (sessions.data ?? []).filter((session) => session.includeInAgg && session.msiPct !== null && session.durationS > 0);
  const totalS = counted.reduce((sum, session) => sum + session.durationS, 0);
  const sickness = totalS > 0 ? counted.reduce((sum, session) => sum + (session.msiPct ?? 0) * session.durationS, 0) / totalS : null;
  if (error) return <ErrorAlert title="The overview" error={error} onRetry={() => void refetch()} className="max-w-sm" />;
  if (isPending) return <Skeleton className="h-14 w-72" />;
  const items = [
    { label: "Trips", value: `${data.sessions.includedInAgg} / ${data.sessions.total}` },
    { label: "Distance", value: formatDistance(data.distanceKm * METERS_PER_KM) },
    { label: "Roads", value: formatNumber(data.segments) },
    { label: "Potholes", value: formatNumber(data.confirmedPotholes) },
    { label: "Sickness / h", value: formatPercent(sickness) },
  ];
  return (
    <section
      aria-label="Dataset overview"
      title={`Last processed ${formatDateTime(data.lastProcessedAt)}`}
      className={stacked ? "vertical gap-3" : "border border-white/10 bg-card/70 shadow-lg backdrop-blur-md rounded-2xl px-4 py-2"}
    >
      <dl className={stacked ? "grid grid-cols-2 gap-x-4 gap-y-3" : "horizontal gap-5"}>
        {items.map((item) => (
          <div key={item.label} className="vertical leading-tight">
            <dt className="text-[10px] tracking-wide text-muted-foreground uppercase">{item.label}</dt>
            <dd className="text-sm font-semibold tabular-nums text-foreground">{item.value}</dd>
          </div>
        ))}
      </dl>
      {stacked && <p className="text-[11px] text-muted-foreground">Last processed {formatDateTime(data.lastProcessedAt)}</p>}
    </section>
  );
}
