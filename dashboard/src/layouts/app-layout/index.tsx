import { Link, useRouteContext } from "@tanstack/react-router";
import { Activity, Gauge, Map as MapIcon, Menu, Radio, type LucideIcon } from "lucide-react";
import { useState, type ReactNode } from "react";

import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { DataSourceSettings } from "@/features/data-source-settings";
import { cn } from "@/lib/utils";
import { OverviewStrip } from "@/views/map/components/overview-strip";

interface NavItem {
  to: "/live" | "/map" | "/sessions";
  label: string;
  icon: LucideIcon;
}

/** The dashboard's pages in the order of plan 02 §5: the live view is the main screen. */
const NAV_ITEMS: NavItem[] = [
  { to: "/live", label: "Live", icon: Radio },
  { to: "/map", label: "Map", icon: MapIcon },
  { to: "/sessions", label: "Sessions", icon: Activity },
];

const GLASS = "border border-white/10 bg-card/70 shadow-lg backdrop-blur-md";

const dockLinkClass =
  "rounded-full px-3.5 py-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";

const menuLinkClass =
  "horizontal gap-3 rounded-md px-3 py-2.5 text-base font-medium text-muted-foreground transition-colors hover:bg-background-hover hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";

export function AppLayout({ children }: { children: ReactNode }) {
  const { dataSource } = useRouteContext({ from: "__root__" });
  const [open, setOpen] = useState(false);
  return (
    <div className="vertical min-h-svh bg-background">
      <a href="#content" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded-md focus:bg-card focus:p-2">
        Skip to content
      </a>

      {/* Desktop: a small floating dock instead of a bar, so the map owns the whole screen. */}
      <nav aria-label="Main" className={cn("fixed top-3 left-3 z-40 hidden items-center gap-1 rounded-full p-1 sm:flex", GLASS)}>
        <Link to="/live" aria-label="Road &amp; Ride" className="grid size-8 place-items-center rounded-full bg-accent text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
          <Gauge className="size-4" aria-hidden="true" />
        </Link>
        <ul className="horizontal gap-0.5">
          {NAV_ITEMS.map(({ to, label }) => (
            <li key={to}>
              <Link
                to={to}
                className={dockLinkClass}
                activeOptions={{ includeSearch: false }}
                activeProps={{ className: cn(dockLinkClass, "bg-muted text-foreground"), "aria-current": "page" }}
              >
                {label}
              </Link>
            </li>
          ))}
        </ul>
        <DataSourceSettings dataSource={dataSource} iconOnly />
      </nav>

      {/* Phone: one round button that opens everything. */}
      <Sheet open={open} onOpenChange={setOpen}>
        <SheetTrigger asChild>
          <button
            type="button"
            aria-label="Menu"
            className={cn("fixed top-3 left-3 z-40 grid size-11 place-items-center rounded-full text-foreground transition-colors hover:bg-card focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:hidden", GLASS)}
          >
            <Menu className="size-5" aria-hidden="true" />
          </button>
        </SheetTrigger>
        <SheetContent side="left" className="w-72 sm:hidden sm:max-w-72">
          <SheetHeader>
            <SheetTitle className="horizontal gap-2">
              <span className="grid size-8 place-items-center rounded-lg bg-accent text-accent-foreground">
                <Gauge className="size-5" aria-hidden="true" />
              </span>
              Road &amp; Ride
            </SheetTitle>
            <SheetDescription>Road quality · motion sickness</SheetDescription>
          </SheetHeader>
          <nav aria-label="Menu" className="px-3">
            <ul className="vertical gap-1">
              {NAV_ITEMS.map(({ to, label, icon: Icon }) => (
                <li key={to}>
                  <Link
                    to={to}
                    onClick={() => setOpen(false)}
                    className={menuLinkClass}
                    activeOptions={{ includeSearch: false }}
                    activeProps={{ className: cn(menuLinkClass, "bg-muted text-foreground"), "aria-current": "page" }}
                  >
                    <Icon className="size-5" aria-hidden="true" />
                    {label}
                  </Link>
                </li>
              ))}
            </ul>
          </nav>
          <div className="px-4">
            <OverviewStrip stacked />
          </div>
          <div className="mt-auto px-3 pb-4">
            <DataSourceSettings dataSource={dataSource} />
          </div>
        </SheetContent>
      </Sheet>

      <div id="content" className="vertical flex-1">
        {children}
      </div>
    </div>
  );
}
