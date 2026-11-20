import { StatCard } from "@/components/stat-card";
import type { SessionDetail } from "@/types/sessions";
import { formatDuration } from "@/utils/format-date-time";
import { formatDistance, formatFraction, formatMsdv, formatPercent } from "@/utils/format-number";

export function SessionStats({ session }: { session: SessionDetail }) {
  return (
    <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
      <StatCard label="Duration" value={formatDuration(session.durationS)} />
      <StatCard label="Distance" value={formatDistance(session.distanceM)} />
      <StatCard label="MSDV (vertical)" value={formatMsdv(session.msdvZ)} hint="ISO 2631-1, Wf weighting" />
      <StatCard
        label="May vomit"
        value={formatPercent(session.msiPct)}
        hint={session.sicknessExperimental ? "Experimental: mount not rigid" : "Predicted, ≈ MSDV / 3"}
      />
      <StatCard label="Valid data" value={formatFraction(session.validFraction)} />
      <StatCard
        label="Events"
        value={session.eventCounts.pothole + session.eventCounts.speed_bump}
        hint={`${session.eventCounts.pothole} potholes · ${session.eventCounts.speed_bump} bumps${session.eventCounts.rail_joint ? ` · ${session.eventCounts.rail_joint} rail joints` : ""}`}
      />
    </div>
  );
}
