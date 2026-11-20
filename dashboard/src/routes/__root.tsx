import { createRootRouteWithContext, Outlet } from "@tanstack/react-router";

import { AppLayout } from "@/layouts/app-layout";
import { NotFoundPage } from "@/pages/not-found";
import type { RouterContext } from "@/types/router";

export const Route = createRootRouteWithContext<RouterContext>()({
  component: RootComponent,
  notFoundComponent: NotFoundPage,
});

function RootComponent() {
  return (
    <AppLayout>
      <Outlet />
    </AppLayout>
  );
}
