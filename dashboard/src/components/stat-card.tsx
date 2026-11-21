import type { ReactNode } from "react";

import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";

interface StatCardProps {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
  icon?: ReactNode;
  className?: string;
}

export function StatCard({ label, value, hint, icon, className }: StatCardProps) {
  return (
    <Card className={cn("gap-0 py-0", className)}>
      <CardContent className="vertical gap-1 p-3 sm:p-4">
        <div className="horizontal justify-between gap-2 text-xs font-medium tracking-wide text-muted-foreground uppercase">
          <span>{label}</span>
          {icon && <span aria-hidden="true">{icon}</span>}
        </div>
        <div className="text-xl font-semibold tabular-nums whitespace-nowrap text-foreground sm:text-2xl">{value}</div>
        {hint && <div className="text-xs text-muted-foreground">{hint}</div>}
      </CardContent>
    </Card>
  );
}
