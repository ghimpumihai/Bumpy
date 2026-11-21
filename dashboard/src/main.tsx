import { QueryClientProvider, type QueryClient } from "@tanstack/react-query";
import { createRouter, RouterProvider } from "@tanstack/react-router";
import { MotionConfig } from "motion/react";
import { ThemeProvider } from "next-themes";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { HelmetProvider } from "react-helmet-async";

import { RouteError } from "@/components/route-error";
import { StartupError } from "@/components/startup-error";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { configureApiClient } from "@/config/api-client";
import { resolveDataSource } from "@/config/runtime-config";
import { createQueryClient } from "@/config/query-client";

import "./global.css";
import { routeTree } from "./routeTree.gen";

function createAppRouter(queryClient: QueryClient, dataSource: Awaited<ReturnType<typeof resolveDataSource>>) {
  return createRouter({
    routeTree,
    context: { queryClient, dataSource },
    defaultPreload: "intent",
    defaultErrorComponent: RouteError,
    scrollRestoration: true,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createAppRouter>;
  }
}

function rootElement(): HTMLElement {
  const root = document.getElementById("root");
  if (!root) throw new Error("#root element missing from index.html");
  return root;
}

async function bootstrap() {
  const dataSource = await resolveDataSource();
  await configureApiClient(dataSource);
  const queryClient = createQueryClient();
  const router = createAppRouter(queryClient, dataSource);

  createRoot(rootElement()).render(
    <StrictMode>
      <HelmetProvider>
        <ThemeProvider
          attribute="class"
          defaultTheme="dark"
          forcedTheme="dark"
          disableTransitionOnChange
          // The anti-flash script only matters for server rendering; in this SPA React would warn about it.
          scriptProps={{ type: "application/json" }}
        >
          <QueryClientProvider client={queryClient}>
            <MotionConfig reducedMotion="user">
              <TooltipProvider delayDuration={200}>
                <RouterProvider router={router} />
                <Toaster richColors closeButton />
              </TooltipProvider>
            </MotionConfig>
          </QueryClientProvider>
        </ThemeProvider>
      </HelmetProvider>
    </StrictMode>,
  );
}

// A failed start (no API URL for an explicit API choice, a stale lazy chunk after a redeploy, …)
// shows a message instead of a blank page.
bootstrap().catch((error: unknown) => {
  console.error(error);
  createRoot(rootElement()).render(<StartupError message={error instanceof Error ? error.message : String(error)} />);
});
