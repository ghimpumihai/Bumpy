import { createFileRoute } from "@tanstack/react-router";

import { SessionsPage } from "@/pages/sessions";
import { sessionsSearchSchema } from "@/views/sessions/schema";

export const Route = createFileRoute("/sessions/")({
  validateSearch: sessionsSearchSchema,
  component: SessionsPage,
});
