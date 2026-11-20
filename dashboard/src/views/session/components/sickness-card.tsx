import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { SicknessSummary } from "@/types/sessions";
import { formatTime } from "@/utils/format-date-time";
import { formatMsdv, formatNumber } from "@/utils/format-number";

import { MAX_RATING_ROWS } from "../utils/constants";


/** The ISO prediction next to what the passenger actually reported (plan 02 §9 step 6). */
export function SicknessCard({ sickness }: { sickness: SicknessSummary }) {
  const ratings = sickness.ratings.slice(-MAX_RATING_ROWS);
  return (
    <Card>
      <CardHeader>
        <CardTitle>Prediction vs. passenger ratings</CardTitle>
        <CardDescription>
          MISC 0 = no problems … 6 = some nausea … 10 = vomiting. Rank correlation with MSDV so far:{" "}
          <span className="font-medium text-foreground">{formatNumber(sickness.spearman, 2)}</span>
        </CardDescription>
      </CardHeader>
      <CardContent>
        {ratings.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Time</TableHead>
                <TableHead className="text-right">MISC</TableHead>
                <TableHead className="text-right">MSDV so far</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {ratings.map((rating) => (
                <TableRow key={rating.tUtc}>
                  <TableCell className="tabular-nums">{formatTime(rating.tUtc)}</TableCell>
                  <TableCell className="text-right tabular-nums">{rating.value}</TableCell>
                  <TableCell className="text-right tabular-nums">{formatMsdv(rating.msdvSoFar)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">No ratings were given in this session.</p>
        )}
      </CardContent>
    </Card>
  );
}
