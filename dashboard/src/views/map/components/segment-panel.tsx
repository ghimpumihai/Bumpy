import { Link } from "@tanstack/react-router";

import { segmentsApi } from "@/api/segments";
import { QueryState } from "@/components/query-state";
import { StatCard } from "@/components/stat-card";
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
  // Trips that are not counted in the road's numbers are not listed either.
  const passes = detail?.observations.filter((obs) => obs.includedInAgg) ?? [];
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
                      label="Pothole"
                      value={road.potholeConfirmed ? "Confirmed" : "None"}
                      hint={road.potholeConfirmed ? "several trips hit one here" : "no pothole confirmed here"}
                    />
                    <StatCard label="Sickness" value={formatPercent(road.msi1hPct)} hint="may feel sick per hour" />
                  </section>
                )}

                <section className="vertical gap-2">
                  <h3 className="text-sm font-medium">Passes ({passes.length})</h3>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>When</TableHead>
                        <TableHead className="text-right">Speed</TableHead>
                        <TableHead className="text-right">Raw roughness</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {passes.map((obs) => (
                        <TableRow key={`${obs.sessionId}-${obs.tStart}`}>
                          <TableCell>
                            <Link to="/sessions/$sessionId" params={{ sessionId: obs.sessionId }} className="underline-offset-4 hover:underline">
                              {formatDateTime(obs.tStart)}
                            </Link>
                          </TableCell>
                          <TableCell className="text-right tabular-nums">{formatKmh(obs.speedKmh)}</TableCell>
                          <TableCell className="text-right tabular-nums">{formatAcceleration(obs.roughnessRms)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </section>
                <p className="text-xs text-muted-foreground">
                  Updated {formatDateTime(detail.updatedAt)}
                </p>
              </>
            )}
          </QueryState>
        </div>
      </SheetContent>
    </Sheet>
  );
}
