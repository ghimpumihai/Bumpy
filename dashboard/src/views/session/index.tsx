import { useParams } from "@tanstack/react-router";

import { sessionsApi } from "@/api/sessions";
import { QueryState } from "@/components/query-state";
import { Skeleton } from "@/components/ui/skeleton";
import { QualityPanel } from "@/features/data-quality/quality-panel";

import { ContextCard } from "./components/context-card";
import { DetectionCard } from "./components/detection-card";
import { SessionHeader } from "./components/session-header";
import { SessionStats } from "./components/session-stats";
import { TrackMap } from "./components/track-map";

export function SessionView() {
  const { sessionId } = useParams({ from: "/sessions/$sessionId" });
  const query = sessionsApi.useSession(sessionId);
  const session = query.data;
  return (
    <main className="mx-auto vertical w-full max-w-7xl gap-6 px-4 py-6 sm:px-6">
      <QueryState
        isPending={query.isPending}
        error={query.error}
        onRetry={() => void query.refetch()}
        skeleton={
          <div className="vertical gap-4">
            <Skeleton className="h-10 w-80" />
            <Skeleton className="h-24 w-full" />
            <Skeleton className="h-96 w-full" />
          </div>
        }
      >
        {session && (
          <>
            <SessionHeader session={session} />
            <SessionStats session={session} />
            <TrackMap sessionId={session.sessionId} isLive={session.status === "live"} />
            <div className="grid gap-6 lg:grid-cols-2">
              <DetectionCard detection={session.detection} />
              <ContextCard session={session} />
            </div>
            <QualityPanel quality={session.quality} />
          </>
        )}
      </QueryState>
    </main>
  );
}
