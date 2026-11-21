import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PLACEHOLDER } from "@/constants";
import { ExclusionReason, type SessionDetail } from "@/types/sessions";
import { formatDateTime } from "@/utils/format-date-time";

const UNKNOWN_CONTEXT_TEXT = "unknown (session.json not received)";

/** Session context from session.json: needed to tell a bumpy bus from a bumpy road (plan 02 §3). */
export function ContextCard({ session }: { session: SessionDetail }) {
  // Until session.json arrives the read API fills the context with empty defaults; don't present those
  // as what the operator entered.
  const known = !session.exclusionReasons.includes(ExclusionReason.UNKNOWN_CONTEXT);
  const orUnknown = (value: string) => (known && value.trim() ? value : UNKNOWN_CONTEXT_TEXT);
  const rows = [
    { label: "Vehicle", value: orUnknown([session.vehicle.makeModel, session.vehicle.line && `line ${session.vehicle.line}`].filter(Boolean).join(", ")) },
    { label: "Mount", value: known && session.mount.location ? `${session.mount.location}${session.mount.rigid ? " (rigid)" : " (not rigid)"}` : UNKNOWN_CONTEXT_TEXT },
    { label: "Phone orientation", value: orUnknown(session.mount.phoneOrientation) },
    { label: "Rater", value: known ? [session.people.raterSeat, session.people.raterPosture].filter(Boolean).join(", ") : UNKNOWN_CONTEXT_TEXT },
    { label: "Passengers", value: known ? String(session.people.passengerCount) : UNKNOWN_CONTEXT_TEXT },
    { label: "Device", value: session.deviceId ?? PLACEHOLDER },
    { label: "Processed", value: `${formatDateTime(session.processedAt)}${session.processorVersion ? ` · ${session.processorVersion}` : ""}` },
  ];
  return (
    <Card>
      <CardHeader>
        <CardTitle>Context</CardTitle>
      </CardHeader>
      <CardContent>
        <dl className="vertical gap-2 text-sm">
          {rows.map((row) => (
            <div key={row.label} className="grid grid-cols-[9rem_1fr] gap-2">
              <dt className="text-muted-foreground">{row.label}</dt>
              <dd className="break-words">{row.value}</dd>
            </div>
          ))}
        </dl>
      </CardContent>
    </Card>
  );
}
