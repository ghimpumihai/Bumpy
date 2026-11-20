import { qualityApi } from "@/api/quality";
import { PLACEHOLDER } from "@/constants";
import { QueryState } from "@/components/query-state";
import { StatCard } from "@/components/stat-card";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { QualityStatus } from "@/types/common";

import { QualityTable } from "./components/quality-table";

export function QualityView() {
  const query = qualityApi.useQuality();
  const rows = query.data ?? [];
  // No counts until data exists, so a failed request doesn't read as "0 bad sessions".
  const count = (status: QualityStatus) => (query.data ? rows.filter((row) => row.qualityStatus === status).length : PLACEHOLDER);
  return (
    <div className="vertical gap-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatCard label="Good" value={count(QualityStatus.OK)} hint="No problems found" />
        <StatCard label="Degraded" value={count(QualityStatus.DEGRADED)} hint="Counted, invalid windows skipped" />
        <StatCard label="Bad" value={count(QualityStatus.BAD)} hint="Kept out of the map automatically" />
        <StatCard label="Excluded from roughness" value={query.data ? rows.filter((row) => !row.roughnessEligible).length : PLACEHOLDER} hint="Hand-held or loose mount" />
      </div>
      <Card className="py-0">
        <CardContent className="p-0">
          <QueryState
            isPending={query.isPending}
            error={query.error}
            onRetry={() => void query.refetch()}
            isEmpty={rows.length === 0}
            emptyMessage="No sessions yet."
            skeleton={<Skeleton className="m-4 h-64" />}
          >
            <QualityTable rows={rows} />
          </QueryState>
        </CardContent>
      </Card>
      <p className="text-xs text-muted-foreground">
        Motion rate: worst of device motion, raw accelerometer and gyroscope (expected 100 Hz; amber below 90 Hz). Longest gap in red
        above 1 s. Invalid time: phone moved, gravity drift, gyro/GPS disagreement, poor GPS.
      </p>
    </div>
  );
}
