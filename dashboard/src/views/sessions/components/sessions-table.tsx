import { Link } from "@tanstack/react-router";
import { Check, Minus } from "lucide-react";

import { MockBadge, QualityBadge, SourceBadge } from "@/components/status/session-badges";
import { VehicleLabel } from "@/components/status/vehicle-label";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { EXCLUSION_LABELS } from "@/constants/sessions";
import type { SessionSummary } from "@/types/sessions";
import { formatDateTime, formatDuration } from "@/utils/format-date-time";
import { formatDistance, formatFraction, formatPercent } from "@/utils/format-number";

function AggregationCell({ session }: { session: SessionSummary }) {
  const reasons = session.exclusionReasons.map((reason) => EXCLUSION_LABELS[reason]);
  const icon = session.includeInAgg ? (
    <Check className="size-4 text-success" aria-label="Included in the aggregated map" />
  ) : (
    <Minus className="size-4 text-muted-foreground" aria-label="Not included in the aggregated map" />
  );
  if (reasons.length === 0) return icon;
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button type="button" className="rounded-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring" aria-label={reasons.join(". ")}>
          {icon}
        </button>
      </TooltipTrigger>
      <TooltipContent className="max-w-64">{reasons.join(" · ")}</TooltipContent>
    </Tooltip>
  );
}

export function SessionsTable({ sessions }: { sessions: SessionSummary[] }) {
  return (
    <Table>
      <TableCaption className="sr-only">Recorded sessions, newest first</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Started</TableHead>
          <TableHead>Vehicle</TableHead>
          <TableHead>Source</TableHead>
          <TableHead className="text-right">Duration</TableHead>
          <TableHead className="text-right">Distance</TableHead>
          <TableHead>Quality</TableHead>
          <TableHead className="text-center">On map</TableHead>
          <TableHead className="text-right">Sickness</TableHead>
          <TableHead className="text-right">Potholes</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {sessions.map((session) => (
          <TableRow key={session.sessionId}>
            <TableCell className="whitespace-nowrap">
              <Link
                to="/sessions/$sessionId"
                params={{ sessionId: session.sessionId }}
                className="font-medium text-accent underline-offset-4 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                {formatDateTime(session.startedAt)}
              </Link>
            </TableCell>
            <TableCell>
              <VehicleLabel type={session.vehicle.type} line={session.vehicle.line} detail={session.vehicle.makeModel} />
            </TableCell>
            <TableCell>
              <span className="horizontal gap-1">
                <SourceBadge source={session.source} />
                {session.isMock && <MockBadge />}
              </span>
            </TableCell>
            <TableCell className="text-right tabular-nums">{formatDuration(session.durationS)}</TableCell>
            <TableCell className="text-right tabular-nums">{formatDistance(session.distanceM)}</TableCell>
            <TableCell>
              <span className="horizontal gap-2">
                <QualityBadge status={session.qualityStatus} />
                <span className="text-xs tabular-nums text-muted-foreground">{formatFraction(session.validFraction)} valid</span>
              </span>
            </TableCell>
            <TableCell className="text-center">
              <span className="inline-flex justify-center">
                <AggregationCell session={session} />
              </span>
            </TableCell>
            <TableCell className="text-right tabular-nums">
              {formatPercent(session.msiPct)}
              {session.sicknessExperimental && <span className="text-muted-foreground"> *</span>}
            </TableCell>
            <TableCell className="text-right tabular-nums">{session.eventCounts.pothole}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
