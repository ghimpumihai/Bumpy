import { AlertTriangle } from "lucide-react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { GENERIC_ERROR_MESSAGE } from "@/constants";
import { cn } from "@/lib/utils";
import { describeError } from "@/utils/describe-error";

interface ErrorAlertProps {
  error: unknown;
  /** What failed, e.g. "Track"; defaults to a generic title. */
  title?: string;
  onRetry?: () => void;
  className?: string;
}

/** A failed request: what failed, why, and a retry button. */
export function ErrorAlert({ error, title, onRetry, className }: ErrorAlertProps) {
  return (
    <Alert variant="destructive" role="alert" className={cn("bg-card", className)}>
      <AlertTriangle aria-hidden="true" />
      <AlertTitle>{title ? `${title} could not be loaded.` : GENERIC_ERROR_MESSAGE}</AlertTitle>
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
