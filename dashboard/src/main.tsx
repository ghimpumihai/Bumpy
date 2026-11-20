import { QueryClientProvider, type QueryClient } from "@tanstack/react-query";
import { createRouter, RouterProvider } from "@tanstack/react-router";
import { ThemeProvider } from "next-themes";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { HelmetProvider } from "react-helmet-async";

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
    scrollRestoration: true,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createAppRouter>;
  }
}

async function bootstrap() {
  const dataSource = await resolveDataSource();
  await configureApiClient(dataSource);
  const queryClient = createQueryClient();
  const router = createAppRouter(queryClient, dataSource);
  const root = document.getElementById("root");
  if (!root) throw new Error("#root element missing from index.html");

  createRoot(root).render(
    <StrictMode>
      <HelmetProvider>
        <ThemeProvider
          attribute="class"
          defaultTheme="system"
          enableSystem
          disableTransitionOnChange
          // The anti-flash script only matters for server rendering; in this SPA React would warn about it.
          scriptProps={{ type: "application/json" }}
        >
          <QueryClientProvider client={queryClient}>
            <TooltipProvider delayDuration={200}>
              <RouterProvider router={router} />
              <Toaster richColors closeButton />
            </TooltipProvider>
          </QueryClientProvider>
        </ThemeProvider>
      </HelmetProvider>
    </StrictMode>,
  );
}

void bootstrap();
