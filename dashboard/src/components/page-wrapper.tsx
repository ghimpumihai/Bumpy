import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

interface PageWrapperProps {
  title: string;
  description?: ReactNode;
  /** Controls shown on the right of the title (filters, actions). */
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}

/** Standard content page: heading, optional actions and a padded, width-limited body. */
export function PageWrapper({ title, description, actions, children, className }: PageWrapperProps) {
  return (
    <main className={cn("mx-auto vertical w-full max-w-7xl gap-6 px-4 py-6 sm:px-6", className)}>
      <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div className="vertical gap-1">
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">{title}</h1>
          {description && <p className="max-w-3xl text-sm text-muted-foreground">{description}</p>}
        </div>
        {actions && <div className="horizontal flex-wrap gap-2">{actions}</div>}
      </header>
      {children}
    </main>
  );
}
