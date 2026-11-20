import { sessionsApi } from "@/api/sessions";
import { TimeSeriesChart } from "@/components/charts/time-series-chart";
import { QueryState } from "@/components/query-state";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import type { SessionDetail } from "@/types/sessions";

import { CHART_HEIGHT_PX } from "../utils/constants";
import { buildChartData } from "../utils/series";


/** The road band, the sickness band and their context on one synchronized time axis. */
export function SessionCharts({ session }: { session: SessionDetail }) {
  const series = sessionsApi.useSessionSeries(session.sessionId, session.status);
  const events = sessionsApi.useSessionEvents(session.sessionId, session.status);
  const data = series.data ? buildChartData(series.data, events.data, session.sickness.ratings) : null;
  const syncKey = `session-${session.sessionId}`;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Signals</CardTitle>
        <CardDescription>
          Downsampled to about 5 Hz. Hover one chart to read all of them at the same moment; drag to zoom, double-click to reset.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <QueryState
          isPending={series.isPending}
          error={series.error}
            hasData={series.data !== undefined}
          onRetry={() => void series.refetch()}
          isEmpty={data?.times.length === 0}
          skeleton={<Skeleton className="h-[42rem] w-full" />}
        >
          {data && (
            <div className="vertical gap-6">
              <TimeSeriesChart
                title="Vertical acceleration — road band, with detected events"
                times={data.times}
                height={CHART_HEIGHT_PX}
                syncKey={syncKey}
                series={[
                  { label: "Vertical", colorVar: "--chart-1", values: data.aVert, unit: "m/s²" },
                  { label: "Pothole", colorVar: "--event-pothole", values: data.potholes, pointsOnly: true },
                  { label: "Speed bump", colorVar: "--event-speed-bump", values: data.speedBumps, pointsOnly: true },
                ]}
              />
              <TimeSeriesChart
                title="Sideways and forward acceleration — sway in curves and stop-and-go"
                times={data.times}
                height={CHART_HEIGHT_PX}
                syncKey={syncKey}
                series={[
                  { label: "Lateral", colorVar: "--chart-2", values: data.aLat, unit: "m/s²" },
                  { label: "Longitudinal", colorVar: "--chart-3", values: data.aLon, unit: "m/s²" },
                ]}
              />
              <TimeSeriesChart
                title="Speed"
                times={data.times}
                height={CHART_HEIGHT_PX}
                syncKey={syncKey}
                series={[{ label: "Speed", colorVar: "--chart-4", values: data.speedKmh, unit: "km/h" }]}
              />
              <TimeSeriesChart
                title="Motion sickness dose so far, and the passenger's MISC ratings"
                times={data.times}
                height={CHART_HEIGHT_PX}
                syncKey={syncKey}
                series={[
                  { label: "MSDV", colorVar: "--chart-5", values: data.msdv, unit: "m/s¹·⁵" },
                  { label: "MISC rating", colorVar: "--chart-1", values: data.ratings, pointsOnly: true, axis: "right", unit: "0–10" },
                ]}
              />
            </div>
          )}
        </QueryState>
      </CardContent>
    </Card>
  );
}
