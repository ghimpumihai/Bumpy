import { createFileRoute } from "@tanstack/react-router";

import { SessionPage } from "@/pages/session";

export const Route = createFileRoute("/sessions/$sessionId")({
  component: SessionPage,
});
