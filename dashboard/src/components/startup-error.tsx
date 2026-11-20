import { AlertTriangle, RotateCcw } from "lucide-react";

import { Button } from "@/components/ui/button";
import { writeDataSourceOverride } from "@/config/runtime-config";

interface StartupErrorProps {
  message: string;
}

/** Shown instead of the app when it cannot start (no providers are available at this point). */
export function StartupError({ message }: StartupErrorProps) {
  const resetAndReload = () => {
    writeDataSourceOverride(null);
    window.location.assign(window.location.pathname);
  };
  return (
    <main className="mx-auto vertical min-h-svh max-w-lg justify-center gap-4 p-6" role="alert">
      <div className="horizontal gap-2 text-destructive">
        <AlertTriangle aria-hidden="true" />
        <h1 className="text-lg font-semibold">The dashboard could not start</h1>
      </div>
      <p className="text-sm text-muted-foreground">{message}</p>
      <div className="horizontal gap-2">
        <Button onClick={() => window.location.reload()}>Reload</Button>
        <Button variant="outline" leftIcon={<RotateCcw />} onClick={resetAndReload}>
          Reset data source and reload
        </Button>
      </div>
    </main>
  );
}
