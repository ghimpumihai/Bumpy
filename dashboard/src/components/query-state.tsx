import { Inbox } from "lucide-react";
import type { ReactNode } from "react";

import { ErrorAlert } from "@/components/error-alert";
import { Skeleton } from "@/components/ui/skeleton";

interface QueryStateProps {
  isPending: boolean;
  error: unknown;
  isEmpty?: boolean;
  emptyMessage?: ReactNode;
  onRetry?: () => void;
  /** Shape of the loading placeholder. */
  skeleton?: ReactNode;
  children: ReactNode;
}

/** Loading, error, empty and success states of one query, handled the same way everywhere. */
export function QueryState({ isPending, error, isEmpty, emptyMessage, onRetry, skeleton, children }: QueryStateProps) {
  if (isPending) return <>{skeleton ?? <Skeleton className="h-40 w-full" />}</>;
  if (error) return <ErrorAlert error={error} onRetry={onRetry} />;
  if (isEmpty) {
    return (
      <div className="vertical items-center gap-2 rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
        <Inbox className="size-6" aria-hidden="true" />
        {emptyMessage ?? "Nothing to show yet."}
      </div>
    );
  }
  return <>{children}</>;
}
