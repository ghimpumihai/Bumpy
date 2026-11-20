import { overviewApi } from "@/api/overview";
import { QueryState } from "@/components/query-state";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { VEHICLE_LABELS } from "@/constants/sessions";
import type { VehicleType } from "@/types/common";
import { formatDateTime } from "@/utils/format-date-time";
import { formatNumber } from "@/utils/format-number";

const isVehicleType = (value: string): value is VehicleType => value in VEHICLE_LABELS;

/** The current fit of log(roughness) = segment + vehicle + β·log(speed). */
export function ModelFitCard() {
  const query = overviewApi.useOverview();
  const fit = query.data?.aggregation;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Current cross-vehicle fit</CardTitle>
        <CardDescription>Re-fitted by the aggregation step after every processed session.</CardDescription>
      </CardHeader>
      <CardContent>
        <QueryState isPending={query.isPending} error={query.error} onRetry={() => void query.refetch()}>
          {fit && (
            <div className="vertical gap-3 text-sm">
              <p>
                Method: <span className="font-medium">{fit.method === "model" ? "regression model" : fit.method === "percentile" ? "per-session percentiles (fallback)" : "not fitted yet"}</span>
                {fit.beta !== null && (
                  <>
                    {" "}
                    · speed exponent β = <span className="font-medium tabular-nums">{formatNumber(fit.beta, 2)}</span> (roughness grows with speed^β)
                  </>
                )}
              </p>
              {Object.keys(fit.vehicleEffects).length > 0 && (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Vehicle</TableHead>
                      <TableHead className="text-right">Feels the same road …</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {Object.entries(fit.vehicleEffects).map(([vehicle, effect]) => (
                      <TableRow key={vehicle}>
                        <TableCell>{isVehicleType(vehicle) ? VEHICLE_LABELS[vehicle] : vehicle}</TableCell>
                        <TableCell className="text-right tabular-nums">{effect === 0 ? "reference" : `× ${formatNumber(Math.exp(effect), 2)}`}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
              <p className="text-xs text-muted-foreground">
                Reference speed {formatNumber(fit.refSpeedKmh)} km/h · fitted {formatDateTime(fit.fittedAt)}
              </p>
            </div>
          )}
        </QueryState>
      </CardContent>
    </Card>
  );
}
