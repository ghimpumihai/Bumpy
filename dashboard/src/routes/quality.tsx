import { createFileRoute } from "@tanstack/react-router";

import { QualityPage } from "@/pages/quality";

export const Route = createFileRoute("/quality")({
  component: QualityPage,
});
