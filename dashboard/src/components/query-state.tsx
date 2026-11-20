import { AlertTriangle, Inbox } from "lucide-react";
import type { ReactNode } from "react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { GENERIC_ERROR_MESSAGE } from "@/constants";
import { describeError } from "@/utils/describe-error";

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
  if (error) {
    return (
      <Alert variant="destructive" role="alert">
        <AlertTriangle aria-hidden="true" />
        <AlertTitle>{GENERIC_ERROR_MESSAGE}</AlertTitle>
        <AlertDescription className="vertical items-start gap-2">
          <span>{describeError(error)}</span>
          {onRetry && (
            <Button size="sm" variant="outline" onClick={onRetry}>
              Try again
            </Button>
          )}
        </AlertDescription>
      </Alert>
    );
  }
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
