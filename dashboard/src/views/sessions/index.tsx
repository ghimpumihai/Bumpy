import { sessionsApi } from "@/api/sessions";
import { PLACEHOLDER } from "@/constants";
import { QueryState } from "@/components/query-state";
import { StatCard } from "@/components/stat-card";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { METERS_PER_KM } from "@/constants/units";
import { formatDistance, formatNumber } from "@/utils/format-number";

import { SessionsTable } from "./components/sessions-table";

export function SessionsView() {
  const query = sessionsApi.useSessions();
  const sessions = query.data ?? [];
  const hasData = query.data !== undefined;
  const totalM = sessions.reduce((sum, session) => sum + session.distanceM, 0);
  const potholes = sessions.reduce((sum, session) => sum + session.eventCounts.pothole, 0);
  return (
    <div className="vertical gap-4">
      <div className="grid grid-cols-3 gap-3">
        <StatCard label="Trips" value={hasData ? formatNumber(sessions.length) : PLACEHOLDER} />
        <StatCard label="Distance" value={hasData ? formatDistance(totalM) : PLACEHOLDER} hint={hasData && totalM > METERS_PER_KM ? "in total" : undefined} />
        <StatCard label="Potholes" value={hasData ? formatNumber(potholes) : PLACEHOLDER} />
      </div>
      <Card className="py-0">
        <CardContent className="p-0">
          <QueryState
            isPending={query.isPending}
            error={query.error}
            hasData={hasData}
            onRetry={() => void query.refetch()}
            isEmpty={sessions.length === 0}
            emptyMessage="No trips yet."
            skeleton={<Skeleton className="m-4 h-64" />}
          >
            <SessionsTable sessions={sessions} />
          </QueryState>
        </CardContent>
      </Card>
    </div>
  );
}
