import { Inbox, RefreshCw } from "lucide-react";
import type { ReactNode } from "react";

import { ErrorAlert } from "@/components/error-alert";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { describeError } from "@/utils/describe-error";

interface QueryStateProps {
  isPending: boolean;
  error: unknown;
  /** Data from an earlier successful fetch is on screen. A failed *refresh* then keeps it. */
  hasData?: boolean;
  isEmpty?: boolean;
  emptyMessage?: ReactNode;
  onRetry?: () => void;
  /** Shape of the loading placeholder. */
  skeleton?: ReactNode;
  children: ReactNode;
}

/** A failed background refresh: the content stays, with a small notice instead of an error page. */
function RefreshFailed({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <div role="status" className="horizontal flex-wrap gap-2 rounded-md border border-warning/40 bg-warning/10 px-3 py-1.5 text-xs text-warning">
      <span>Couldn't refresh ({describeError(error)}); showing the last data.</span>
      {onRetry && (
        <Button size="xs" variant="ghost" leftIcon={<RefreshCw />} onClick={onRetry}>
          Retry
        </Button>
      )}
    </div>
  );
}

/** Loading, error, empty and success states of one query, handled the same way everywhere. */
export function QueryState({ isPending, error, hasData = false, isEmpty, emptyMessage, onRetry, skeleton, children }: QueryStateProps) {
  if (isPending) return <>{skeleton ?? <Skeleton className="h-40 w-full" />}</>;
  if (error && !hasData) return <ErrorAlert error={error} onRetry={onRetry} />;
  if (isEmpty) {
    return (
      <div className="vertical items-center gap-2 rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
        <Inbox className="size-6" aria-hidden="true" />
        {emptyMessage ?? "Nothing to show yet."}
      </div>
    );
  }
  return (
    <>
      {Boolean(error) && <RefreshFailed error={error} onRetry={onRetry} />}
      {children}
    </>
  );
}
