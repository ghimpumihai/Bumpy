import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { STREAM_LABELS } from "@/constants/sessions";
import { cn } from "@/lib/utils";
import type { StreamQuality, StreamStatus } from "@/types/sessions";
import { formatHz, formatNumber, formatSeconds } from "@/utils/format-number";

import { streamStatus } from "./utils";

const STATUS_DOT: Record<StreamStatus, string> = {
  ok: "bg-success",
  warn: "bg-warning",
  problem: "bg-destructive",
};
const STATUS_TEXT: Record<StreamStatus, string> = { ok: "OK", warn: "Low rate", problem: "Gaps" };

export function StreamQualityTable({ streams }: { streams: Record<string, StreamQuality> }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Stream</TableHead>
          <TableHead className="text-right">Rows</TableHead>
          <TableHead className="text-right">Rate</TableHead>
          <TableHead className="text-right">Longest gap</TableHead>
          <TableHead className="text-right">Gaps &gt; 1 s</TableHead>
          <TableHead>Status</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {Object.entries(streams).map(([name, stream]) => {
          const status = streamStatus(stream);
          return (
            <TableRow key={name}>
              <TableCell>{STREAM_LABELS[name] ?? name}</TableCell>
              <TableCell className="text-right tabular-nums">{formatNumber(stream.rows)}</TableCell>
              <TableCell className="text-right tabular-nums">
                {formatHz(stream.rateHz, stream.expectedHz !== null && stream.expectedHz < 2 ? 2 : 1)}
                {stream.expectedHz !== null && <span className="text-muted-foreground"> / {formatNumber(stream.expectedHz, stream.expectedHz < 1 ? 1 : 0)}</span>}
              </TableCell>
              <TableCell className={cn("text-right tabular-nums", status === "problem" && "text-destructive")}>{formatSeconds(stream.maxGapS)}</TableCell>
              <TableCell className={cn("text-right tabular-nums", stream.gapsOver1s > 0 && "text-destructive")}>{stream.gapsOver1s}</TableCell>
              <TableCell>
                <span className="horizontal gap-1.5 text-xs">
                  <span className={cn("size-2 rounded-full", STATUS_DOT[status])} aria-hidden="true" />
                  {STATUS_TEXT[status]}
                </span>
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
