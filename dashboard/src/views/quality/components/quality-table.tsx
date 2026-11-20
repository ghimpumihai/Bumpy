import { Link } from "@tanstack/react-router";

import { MockBadge, QualityBadge, SourceBadge } from "@/components/status/session-badges";
import { VehicleLabel } from "@/components/status/vehicle-label";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { STREAM_GAP_PROBLEM_S, STREAM_RATE_WARN_RATIO } from "@/constants/sessions";
import { cn } from "@/lib/utils";
import type { QualityRow } from "@/types/sessions";
import { formatDateTime, formatDuration } from "@/utils/format-date-time";
import { formatFraction, formatHz, formatMeters, formatNumber, formatSeconds } from "@/utils/format-number";

import { MOTION_EXPECTED_HZ } from "../utils/constants";
import { longestMotionGap, totalInvalidSeconds, worstMotionRate } from "../utils/summary";


export function QualityTable({ rows }: { rows: QualityRow[] }) {
  return (
    <Table>
      <TableCaption className="sr-only">Data quality of every session</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Session</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right">Motion rate</TableHead>
          <TableHead className="text-right">Longest gap</TableHead>
          <TableHead className="text-right">GPS fixes</TableHead>
          <TableHead className="text-right">GPS accuracy</TableHead>
          <TableHead className="text-right">Valid</TableHead>
          <TableHead className="text-right">Invalid time</TableHead>
          <TableHead className="text-right">Live batches rejected / late / dup.</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((row) => {
          const rate = worstMotionRate(row);
          const gap = longestMotionGap(row);
          return (
            <TableRow key={row.sessionId}>
              <TableCell>
                <div className="vertical gap-1">
                  <Link to="/sessions/$sessionId" params={{ sessionId: row.sessionId }} className="font-medium text-accent underline-offset-4 hover:underline">
                    {formatDateTime(row.startedAt)}
                  </Link>
                  <span className="horizontal flex-wrap gap-1 text-xs">
                    <VehicleLabel type={row.vehicle.type} line={row.vehicle.line} />
                    <SourceBadge source={row.source} />
                    {row.isMock && <MockBadge />}
                  </span>
                </div>
              </TableCell>
              <TableCell>
                <QualityBadge status={row.qualityStatus} />
              </TableCell>
              <TableCell className={cn("text-right tabular-nums", rate !== null && rate < MOTION_EXPECTED_HZ * STREAM_RATE_WARN_RATIO && "text-warning")}>
                {formatHz(rate)}
              </TableCell>
              <TableCell className={cn("text-right tabular-nums", (gap ?? 0) > STREAM_GAP_PROBLEM_S && "text-destructive")}>{formatSeconds(gap)}</TableCell>
              <TableCell className="text-right tabular-nums">{formatNumber(row.quality.gps.fixes)}</TableCell>
              <TableCell className="text-right tabular-nums">{formatMeters(row.quality.gps.medianHAccM)}</TableCell>
              <TableCell className="text-right tabular-nums">{formatFraction(row.quality.validFraction)}</TableCell>
              <TableCell className="text-right tabular-nums">{formatDuration(totalInvalidSeconds(row))}</TableCell>
              <TableCell className="text-right tabular-nums">
                {row.quality.rejectedBatches} / {row.quality.lateBatches} / {row.quality.duplicateBatches}
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
