import { Link } from "@tanstack/react-router";
import { CircleAlert } from "lucide-react";

import { segmentsApi } from "@/api/segments";
import { QueryState } from "@/components/query-state";
import { StatCard } from "@/components/stat-card";
import { Badge } from "@/components/ui/badge";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { SegmentAggregate } from "@/types/segments";
import { formatDateTime } from "@/utils/format-date-time";
import { PLACEHOLDER } from "@/constants";
import { formatAcceleration, formatFraction, formatKmh, formatPercent } from "@/utils/format-number";

interface SegmentPanelProps {
  h3: string | undefined;
  /** Street the segment is on, when the map could tell. */
  street: string | undefined;
  /** Phone: the panel rises from the bottom instead of the right. */
  narrow: boolean;
  onClose: () => void;
}


function roughnessText(row: SegmentAggregate) {
  if (row.roughnessMethod === "model") return formatAcceleration(row.roughness);
  if (row.roughnessMethod === "percentile") return row.roughnessPctl === null ? PLACEHOLDER : `${formatFraction(row.roughnessPctl)} pctl`;
  return PLACEHOLDER;
}

/** Everything known about one road segment: the road's aggregate (trips, roughness, potholes, sickness), every pass. */
export function SegmentPanel({ h3, street, narrow, onClose }: SegmentPanelProps) {
  const query = segmentsApi.useSegment(h3);
  // While another segment loads, keep the previous one only for the closing animation, never under a new id.
  const switching = query.isPlaceholderData && h3 !== undefined && query.data?.h3 !== h3;
  const detail = switching ? undefined : query.data;
  const road = detail?.byVehicle.find((row) => row.vehicleType === "all");
  return (
    <Sheet open={Boolean(h3)} onOpenChange={(open) => !open && onClose()}>
      <SheetContent side={narrow ? "bottom" : "right"} className="overflow-y-auto data-[side=bottom]:max-h-[55svh] data-[side=right]:w-full data-[side=right]:sm:max-w-xl">
        <SheetHeader>
          <SheetTitle>{street ?? "Road segment"}</SheetTitle>
          <SheetDescription className="text-xs tabular-nums">
            {detail ? `${detail.center.lat.toFixed(5)}, ${detail.center.lon.toFixed(5)}` : ""}
          </SheetDescription>
        </SheetHeader>
        <div className="vertical gap-6 px-4 pb-6">
          <QueryState isPending={query.isPending || switching} error={query.error}
            hasData={query.data !== undefined} onRetry={() => void query.refetch()}>
            {detail && (
              <>
                {road && (
                  <section aria-label="This road" className="grid grid-cols-2 gap-3">
                    <StatCard label="Trips" value={road.nSessions} hint={`${road.nPasses} passes`} />
                    <StatCard label="Roughness" value={roughnessText(road)} hint="vibration at 36 km/h" />
                    <StatCard
                      label="Potholes"
                      value={road.potholeHits === 0 ? "None" : `${road.potholeHits} of ${road.potholePasses}`}
                      hint={
                        road.potholeConfirmed
                          ? "passes hit one · confirmed"
                          : road.potholePasses === 0
                            ? "no pass above 15 km/h"
                            : road.potholeHits === 0
                              ? `none in ${road.potholePasses} passes above 15 km/h`
                              : "passes hit one · not confirmed yet"
                      }
                      icon={road.potholeConfirmed ? <CircleAlert className="size-4 text-destructive" /> : undefined}
                    />
                    <StatCard label="Sickness" value={formatPercent(road.msi1hPct)} hint="may feel sick per hour" />
                  </section>
                )}

                <section className="vertical gap-2">
                  <h3 className="text-sm font-medium">Passes ({detail.observations.length})</h3>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>When</TableHead>
                        <TableHead></TableHead>
                        <TableHead className="text-right">Speed</TableHead>
                        <TableHead className="text-right">Raw roughness</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {detail.observations.map((obs) => (
                        <TableRow key={`${obs.sessionId}-${obs.tStart}`} className={obs.includedInAgg ? undefined : "text-muted-foreground"}>
                          <TableCell>
                            <Link to="/sessions/$sessionId" params={{ sessionId: obs.sessionId }} className="underline-offset-4 hover:underline">
                              {formatDateTime(obs.tStart)}
                            </Link>
                          </TableCell>
                          <TableCell>
                            <span className="horizontal gap-1">
                              {obs.potholeCount > 0 && <Badge variant="destructive">pothole</Badge>}
                              {!obs.includedInAgg && <Badge variant="outline">excluded</Badge>}
                            </span>
                          </TableCell>
                          <TableCell className="text-right tabular-nums">{formatKmh(obs.speedKmh)}</TableCell>
                          <TableCell className="text-right tabular-nums">{formatAcceleration(obs.roughnessRms)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </section>
                <p className="text-xs text-muted-foreground">
                  Pothole ratio {formatFraction(detail.byVehicle.find((r) => r.vehicleType === "all")?.potholeRatio)} · updated{" "}
                  {formatDateTime(detail.updatedAt)}
                </p>
              </>
            )}
          </QueryState>
        </div>
      </SheetContent>
    </Sheet>
  );
}
