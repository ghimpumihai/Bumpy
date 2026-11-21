import { Link } from "@tanstack/react-router";

import { IncompleteBadge, QualityBadge } from "@/components/status/session-badges";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { QualityStatus } from "@/types/common";
import type { SessionSummary } from "@/types/sessions";
import { formatDateTime, formatDuration } from "@/utils/format-date-time";
import { formatDistance, formatPercent } from "@/utils/format-number";

/** One status per trip: closed without Stop reads Incomplete, never Good; Bad stays Bad. */
function TripStatus({ session }: { session: SessionSummary }) {
  if (session.incomplete && session.qualityStatus !== QualityStatus.BAD) return <IncompleteBadge />;
  return <QualityBadge status={session.qualityStatus} />;
}

export function SessionsTable({ sessions }: { sessions: SessionSummary[] }) {
  return (
    <>
      <ul className="divide-y sm:hidden" aria-label="Every trip and what it found">
        {sessions.map((session) => (
          <li key={session.sessionId}>
            <Link to="/sessions/$sessionId" params={{ sessionId: session.sessionId }} className="vertical gap-1 px-4 py-3 active:bg-muted">
              <span className="horizontal justify-between gap-3">
                <span className="font-medium">{formatDateTime(session.startedAt)}</span>
                <TripStatus session={session} />
              </span>
              <span className="text-xs text-muted-foreground tabular-nums">
                {formatDistance(session.distanceM)} · {formatDuration(session.durationS)} · {session.eventCounts.pothole} potholes · {formatPercent(session.msiPct)} sickness / h
              </span>
            </Link>
          </li>
        ))}
      </ul>
      <Table className="hidden sm:table">
      <TableCaption className="sr-only">Every trip and what it found</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Trip</TableHead>
          <TableHead className="text-right">Duration</TableHead>
          <TableHead className="text-right">Distance</TableHead>
          <TableHead className="text-right">Potholes</TableHead>
          <TableHead className="text-right">Sickness / h</TableHead>
          <TableHead>Status</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {sessions.map((session) => (
          <TableRow key={session.sessionId} className="h-12">
            <TableCell>
              <Link to="/sessions/$sessionId" params={{ sessionId: session.sessionId }} className="font-medium text-foreground underline-offset-4 hover:underline">
                {formatDateTime(session.startedAt)}
              </Link>
            </TableCell>
            <TableCell className="text-right tabular-nums text-muted-foreground">{formatDuration(session.durationS)}</TableCell>
            <TableCell className="text-right tabular-nums text-muted-foreground">{formatDistance(session.distanceM)}</TableCell>
            <TableCell className="text-right tabular-nums">{session.eventCounts.pothole}</TableCell>
            <TableCell className="text-right tabular-nums">{formatPercent(session.msiPct)}</TableCell>
            <TableCell>
              <TripStatus session={session} />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
      </Table>
    </>
  );
}
