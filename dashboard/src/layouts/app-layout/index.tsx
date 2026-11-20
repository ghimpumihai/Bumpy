import { Link, useRouteContext } from "@tanstack/react-router";
import { Activity, Gauge, Map as MapIcon, type LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

import { ThemeToggle } from "@/components/theme-toggle";
import { DataSourceSettings } from "@/features/data-source-settings";
import { cn } from "@/lib/utils";

interface NavItem {
  to: "/" | "/sessions";
  label: string;
  icon: LucideIcon;
}

const NAV_ITEMS: NavItem[] = [
  { to: "/", label: "Map", icon: MapIcon },
  { to: "/sessions", label: "Sessions", icon: Activity },
];

const linkClass =
  "horizontal gap-1.5 rounded-md px-2.5 py-1.5 text-sm font-medium text-muted-foreground transition-colors hover:bg-background-hover hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2";

export function AppLayout({ children }: { children: ReactNode }) {
  const { dataSource } = useRouteContext({ from: "__root__" });
  return (
    <div className="vertical min-h-svh bg-background">
      <a href="#content" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded-md focus:bg-card focus:p-2">
        Skip to content
      </a>
      <header className="sticky top-0 z-30 border-b bg-card/95 backdrop-blur">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2 sm:px-6">
          <Link to="/" className="horizontal gap-2 rounded-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
            <span className="gradient-bg grid size-8 place-items-center rounded-lg text-accent-foreground">
              <Gauge className="size-5" aria-hidden="true" />
            </span>
            <span className="vertical leading-tight">
              <span className="text-sm font-semibold text-foreground">Road &amp; Ride</span>
              <span className="text-[11px] text-muted-foreground">Road quality · motion sickness</span>
            </span>
          </Link>
          <nav aria-label="Main" className="order-3 w-full overflow-x-auto sm:order-none sm:w-auto">
            <ul className="horizontal gap-1">
              {NAV_ITEMS.map(({ to, label, icon: Icon }) => (
                <li key={to}>
                  <Link
                    to={to}
                    className={linkClass}
                    activeOptions={{ exact: to === "/", includeSearch: false }}
                    activeProps={{ className: cn(linkClass, "bg-muted text-foreground"), "aria-current": "page" }}
                  >
                    <Icon className="size-4" aria-hidden="true" />
                    {label}
                  </Link>
                </li>
              ))}
            </ul>
          </nav>
          <div className="ml-auto horizontal gap-1">
            <DataSourceSettings dataSource={dataSource} />
            <ThemeToggle />
          </div>
        </div>
      </header>
      <div id="content" className="vertical flex-1">
        {children}
      </div>
    </div>
  );
}
