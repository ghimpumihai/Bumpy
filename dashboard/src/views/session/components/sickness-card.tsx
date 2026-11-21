import { StatCard } from "@/components/stat-card";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { MISC_MAX } from "@/constants/sessions";
import type { SicknessSummary } from "@/types/sessions";
import { formatTime } from "@/utils/format-date-time";
import { formatMsdv, formatNumber, formatPercent } from "@/utils/format-number";

import { MAX_RATING_ROWS } from "../utils/constants";

/** Fewer ratings than this say nothing about how well the model predicts. */
const MIN_RATINGS_FOR_CORRELATION = 5;

/** What the ISO model predicted next to what the passenger reported (plan 02 §9 step 6). */
export function SicknessCard({ sickness, msiPct }: { sickness: SicknessSummary; msiPct: number | null }) {
  const ratings = sickness.ratings;
  const shown = ratings.slice(-MAX_RATING_ROWS);
  const highest = ratings.reduce((max, rating) => Math.max(max, rating.value), 0);
  const enough = ratings.length >= MIN_RATINGS_FOR_CORRELATION;
  return (
    <Card>
      <CardHeader>
        <CardTitle>How sick did this ride make people?</CardTitle>
        <CardDescription>
          The model predicts it from the motion; the passenger reports it on the MISC scale (0 = no problems, 6 = some nausea, 10 = vomiting).
        </CardDescription>
      </CardHeader>
      <CardContent className="vertical gap-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <StatCard label="Predicted" value={formatPercent(msiPct)} hint="may feel sick per hour (ISO 2631-1)" />
          <StatCard label="Reported" value={ratings.length > 0 ? `${highest} / ${MISC_MAX}` : "none"} hint="highest rating given" />
          <StatCard label="Ratings" value={formatNumber(ratings.length)} hint={enough ? `rank correlation ${formatNumber(sickness.spearman, 2)}` : "too few to compare"} />
        </div>
        {shown.length > 0 && (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Time</TableHead>
                <TableHead className="text-right">Reported (MISC)</TableHead>
                <TableHead className="text-right">Motion so far (MSDV)</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((rating) => (
                <TableRow key={rating.tUtc}>
                  <TableCell className="tabular-nums">{formatTime(rating.tUtc)}</TableCell>
                  <TableCell className="text-right tabular-nums">{rating.value}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatMsdv(rating.msdvSoFar)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        <p className="text-xs text-muted-foreground">
          {ratings.length === 0
            ? "No ratings were given in this session."
            : enough
              ? "A handful of rides is an indication, not a validation of the model."
              : "With only a few ratings this is an anecdote, not a validation of the model."}
        </p>
      </CardContent>
    </Card>
  );
}
