import { useNavigate, useSearch } from "@tanstack/react-router";

import { sessionsApi } from "@/api/sessions";
import { QueryState } from "@/components/query-state";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import type { SessionListFilters } from "@/types/sessions";

import { SessionFilters } from "./components/session-filters";
import { SessionsTable } from "./components/sessions-table";
import { ANY_FILTER, type SessionsSearch } from "./schema";
import { TABLE_SKELETON_ROWS } from "./utils/constants";


function toFilters(search: SessionsSearch): SessionListFilters {
  return {
    source: search.source === ANY_FILTER ? undefined : search.source,
    vehicle: search.vehicle === ANY_FILTER ? undefined : search.vehicle,
  };
}

export function SessionsView() {
  const search = useSearch({ from: "/sessions/" });
  const navigate = useNavigate({ from: "/sessions/" });
  const query = sessionsApi.useSessions(toFilters(search));

  return (
    <div className="vertical gap-4">
      <SessionFilters search={search} onChange={(patch) => void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: true })} />
      <Card className="py-0">
        <CardContent className="p-0">
          <QueryState
            isPending={query.isPending}
            error={query.error}
            hasData={query.data !== undefined}
            onRetry={() => void query.refetch()}
            isEmpty={query.data?.length === 0}
            emptyMessage="No sessions match these filters."
            skeleton={
              <div className="vertical gap-2 p-4">
                {Array.from({ length: TABLE_SKELETON_ROWS }, (_, i) => (
                  <Skeleton key={i} className="h-8 w-full" />
                ))}
              </div>
            }
          >
            <SessionsTable sessions={query.data ?? []} />
          </QueryState>
        </CardContent>
      </Card>
      <p className="text-xs text-muted-foreground">* Mount not rigid, hand-held or unknown: sickness numbers are experimental (plan §10).</p>
    </div>
  );
}
