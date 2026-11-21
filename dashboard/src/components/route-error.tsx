import type { ErrorComponentProps } from "@tanstack/react-router";
import { AlertTriangle, RotateCw } from "lucide-react";

import { PageWrapper } from "@/components/page-wrapper";
import { Button } from "@/components/ui/button";
import { describeError } from "@/utils/describe-error";
import { isStaleChunkError } from "@/utils/stale-chunk";

/** A route that failed to load or render: says why, and offers the fix (reload, or try again). */
export function RouteError({ error, reset }: ErrorComponentProps) {
  const staleChunk = isStaleChunkError(error);
  return (
    <PageWrapper
      title={staleChunk ? "A new version of the dashboard is available" : "This page could not be shown"}
      description={staleChunk ? "The dashboard was updated since this tab was opened. Reload to get the new version." : describeError(error)}
    >
      <div role="alert" className="horizontal gap-2">
        <AlertTriangle className="text-destructive" aria-hidden="true" />
        {staleChunk ? (
          <Button leftIcon={<RotateCw />} onClick={() => window.location.reload()}>
            Reload
          </Button>
        ) : (
          <Button variant="outline" onClick={reset}>
            Try again
          </Button>
        )}
      </div>
    </PageWrapper>
  );
}
