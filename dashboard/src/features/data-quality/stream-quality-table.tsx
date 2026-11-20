import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { STREAM_LABELS } from "@/constants/sessions";
import { cn } from "@/lib/utils";
import { StreamStatus, type StreamQuality } from "@/types/sessions";
import { formatHz, formatNumber, formatSeconds } from "@/utils/format-number";

import { expectedRateDigits, rateDigits, streamStatus } from "./utils";

const STATUS_DOT: Record<StreamStatus, string> = {
  [StreamStatus.OK]: "bg-success",
  [StreamStatus.WARN]: "bg-warning",
  [StreamStatus.PROBLEM]: "bg-destructive",
};
const STATUS_TEXT: Record<StreamStatus, string> = {
  [StreamStatus.OK]: "OK",
  [StreamStatus.WARN]: "Low rate",
  [StreamStatus.PROBLEM]: "Gaps",
};

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
                {formatHz(stream.rateHz, rateDigits(stream.expectedHz))}
                {stream.expectedHz !== null && (
                  <span className="text-muted-foreground"> / {formatNumber(stream.expectedHz, expectedRateDigits(stream.expectedHz))}</span>
                )}
              </TableCell>
              <TableCell className={cn("text-right tabular-nums", status === StreamStatus.PROBLEM && "text-destructive")}>{formatSeconds(stream.maxGapS)}</TableCell>
              <TableCell className={cn("text-right tabular-nums", status === StreamStatus.PROBLEM && stream.gapsOver1s > 0 && "text-destructive")}>
                {stream.gapsOver1s}
              </TableCell>
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
