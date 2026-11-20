import { Link } from "@tanstack/react-router";
import { CircleAlert } from "lucide-react";

import { segmentsApi } from "@/api/segments";
import { QueryState } from "@/components/query-state";
import { VehicleLabel } from "@/components/status/vehicle-label";
import { Badge } from "@/components/ui/badge";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { SegmentAggregate } from "@/types/segments";
import { formatDateTime } from "@/utils/format-date-time";
import { PLACEHOLDER } from "@/constants";
import { formatAcceleration, formatFraction, formatKmh, formatPercent } from "@/utils/format-number";

interface SegmentPanelProps {
  h3: string | undefined;
  onClose: () => void;
}

const VEHICLE_ROW_LABEL: Record<SegmentAggregate["vehicleType"], string> = { all: "All", car: "Cars", bus: "Buses", tram: "Trams" };

function roughnessText(row: SegmentAggregate) {
  if (row.roughnessMethod === "model") return formatAcceleration(row.roughness);
  if (row.roughnessMethod === "percentile") return row.roughnessPctl === null ? PLACEHOLDER : `${formatFraction(row.roughnessPctl)} pctl`;
  return PLACEHOLDER;
}

/** Everything known about one road segment: per-vehicle aggregates, sickness by seat, every pass. */
export function SegmentPanel({ h3, onClose }: SegmentPanelProps) {
  const query = segmentsApi.useSegment(h3);
  // While another segment loads, keep the previous one only for the closing animation, never under a new id.
  const switching = query.isPlaceholderData && h3 !== undefined && query.data?.h3 !== h3;
  const detail = switching ? undefined : query.data;
  return (
    <Sheet open={Boolean(h3)} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="overflow-y-auto data-[side=right]:w-full data-[side=right]:sm:max-w-xl">
        <SheetHeader>
          <SheetTitle>Road segment</SheetTitle>
          <SheetDescription className="font-mono text-xs">{h3 ?? detail?.h3}</SheetDescription>
        </SheetHeader>
        <div className="vertical gap-6 px-4 pb-6">
          <QueryState isPending={query.isPending || switching} error={query.error}
            hasData={query.data !== undefined} onRetry={() => void query.refetch()}>
            {detail && (
              <>
                <section className="vertical gap-2">
                  <h3 className="text-sm font-medium">By vehicle</h3>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Vehicle</TableHead>
                        <TableHead className="text-right">Sessions</TableHead>
                        <TableHead className="text-right">Roughness</TableHead>
                        <TableHead className="text-right">Potholes</TableHead>
                        <TableHead className="text-right">Sickness / h</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {detail.byVehicle.map((row) => (
                        <TableRow key={row.vehicleType}>
                          <TableCell>{VEHICLE_ROW_LABEL[row.vehicleType]}</TableCell>
                          <TableCell className="text-right tabular-nums">
                            {row.nSessions} <span className="text-muted-foreground">({row.nPasses} passes)</span>
                          </TableCell>
                          <TableCell className="text-right tabular-nums">{roughnessText(row)}</TableCell>
                          <TableCell className="text-right tabular-nums">
                            <span className="horizontal justify-end gap-1">
                              {row.potholeConfirmed && <CircleAlert className="size-3.5 text-destructive" aria-label="confirmed" />}
                              {row.potholeHits}/{row.potholePasses}
                            </span>
                          </TableCell>
                          <TableCell className="text-right tabular-nums">{formatPercent(row.msi1hPct)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                  <p className="text-xs text-muted-foreground">
                    Potholes: passes above 15 km/h with a detection / all such passes. A pothole is confirmed once enough passes agree.
                  </p>
                </section>

                {detail.sicknessBySeat.length > 0 && (
                  <section className="vertical gap-2">
                    <h3 className="text-sm font-medium">Sickness by seat and posture</h3>
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Vehicle</TableHead>
                          <TableHead>Seat</TableHead>
                          <TableHead className="text-right">Weighted RMS</TableHead>
                          <TableHead className="text-right">Sickness / h</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {detail.sicknessBySeat.map((row) => (
                          <TableRow key={`${row.vehicleType}-${row.raterSeat}-${row.raterPosture}`}>
                            <TableCell>
                              <VehicleLabel type={row.vehicleType} />
                            </TableCell>
                            <TableCell>
                              {row.raterSeat} <span className="text-muted-foreground">· {row.raterPosture}</span>
                            </TableCell>
                            <TableCell className="text-right tabular-nums">{formatAcceleration(row.sicknessAwRms, 3)}</TableCell>
                            <TableCell className="text-right tabular-nums">{formatPercent(row.msi1hPct)}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </section>
                )}

                <section className="vertical gap-2">
                  <h3 className="text-sm font-medium">Passes ({detail.observations.length})</h3>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>When</TableHead>
                        <TableHead>Vehicle</TableHead>
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
                              <VehicleLabel type={obs.vehicleType} />
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
