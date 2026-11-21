import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EVENT_LABELS } from "@/constants/sessions";
import type { DetectionMetrics } from "@/types/sessions";
import { formatFraction } from "@/utils/format-number";

/** Detections scored against the passenger's taps within ±1.5 s (plan 02 §9). */
export function DetectionCard({ detection }: { detection: DetectionMetrics | null }) {
  // Without any manual tap there is nothing to score against: a table of zeros would only look like a result.
  const scored = detection !== null && Object.values(detection).some((score) => score.truePositives + score.falseNegatives > 0);
  if (!scored) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Detection vs. manual taps</CardTitle>
        <CardDescription>A detection counts as correct when a tap of the same type is within ±1.5 s.</CardDescription>
      </CardHeader>
      <CardContent>
        {detection ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Event</TableHead>
                <TableHead className="text-right">Correct</TableHead>
                <TableHead className="text-right">False alarms</TableHead>
                <TableHead className="text-right">Missed</TableHead>
                <TableHead className="text-right">Precision</TableHead>
                <TableHead className="text-right">Recall</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(Object.keys(detection) as (keyof DetectionMetrics)[]).map((type) => {
                const score = detection[type];
                return (
                  <TableRow key={type}>
                    <TableCell>{EVENT_LABELS[type]}</TableCell>
                    <TableCell className="text-right tabular-nums">{score.truePositives}</TableCell>
                    <TableCell className="text-right tabular-nums">{score.falsePositives}</TableCell>
                    <TableCell className="text-right tabular-nums">{score.falseNegatives}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatFraction(score.precision)}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatFraction(score.recall)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">Not scored yet.</p>
        )}
      </CardContent>
    </Card>
  );
}
