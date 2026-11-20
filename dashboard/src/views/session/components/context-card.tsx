import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PLACEHOLDER } from "@/constants";
import type { SessionDetail } from "@/types/sessions";
import { formatDateTime } from "@/utils/format-date-time";

/** Session context from session.json: needed to tell a bumpy bus from a bumpy road (plan 02 §3). */
export function ContextCard({ session }: { session: SessionDetail }) {
  const rows = [
    { label: "Vehicle", value: [session.vehicle.makeModel, session.vehicle.line && `line ${session.vehicle.line}`].filter(Boolean).join(", ") },
    { label: "Mount", value: `${session.mount.location}${session.mount.rigid ? " (rigid)" : " (not rigid)"}` },
    { label: "Phone orientation", value: session.mount.phoneOrientation },
    { label: "Rater", value: `${session.people.raterSeat}, ${session.people.raterPosture}` },
    { label: "Passengers", value: String(session.people.passengerCount) },
    { label: "Audio recording", value: session.audioEnabled ? "on" : "off (public transport)" },
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
