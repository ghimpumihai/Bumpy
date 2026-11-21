import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";

import { IncompleteBadge, QualityBadge } from "@/components/status/session-badges";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { EXCLUSION_LABELS } from "@/constants/sessions";
import type { SessionDetail } from "@/types/sessions";
import { formatDateTime } from "@/utils/format-date-time";

export function SessionHeader({ session }: { session: SessionDetail }) {
  return (
    <header className="vertical gap-3">
      <div>
        <Button asChild variant="ghost" size="sm">
          <Link to="/sessions">
            <ArrowLeft aria-hidden="true" />
            All sessions
          </Link>
        </Button>
      </div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h1 className="text-2xl font-semibold tracking-tight">
          {formatDateTime(session.startedAt)}
        </h1>
        <QualityBadge status={session.qualityStatus} />
        {session.incomplete && <IncompleteBadge />}
      </div>
      <p className="text-sm text-muted-foreground">
        {session.endedAt ? `Ended ${formatDateTime(session.endedAt)}` : session.status === "live" ? "Recording now" : ""} ·{" "}
        <span className="font-mono text-xs">{session.sessionId}</span>
      </p>
      {session.exclusionReasons.length > 0 && (
        <Alert>
          <AlertDescription>
            {session.includeInAgg ? "Partly excluded from the aggregated map: " : "Not counted in the aggregated map: "}
            {session.exclusionReasons.map((reason) => EXCLUSION_LABELS[reason]).join(" · ")}
            {session.replayOf && (
              <>
                {" "}
                · replay of{" "}
                <Link to="/sessions/$sessionId" params={{ sessionId: session.replayOf }} className="text-accent underline-offset-4 hover:underline">
                  the original session
                </Link>
              </>
            )}
          </AlertDescription>
        </Alert>
      )}
    </header>
  );
}
