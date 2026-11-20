import { createFileRoute } from "@tanstack/react-router";

import { LivePage } from "@/pages/live";

export const Route = createFileRoute("/live")({
  component: LivePage,
});
