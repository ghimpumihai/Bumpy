import { createFileRoute } from "@tanstack/react-router";

import { MapPage } from "@/pages/map";
import { mapSearchSchema } from "@/views/map/schema";

export const Route = createFileRoute("/")({
  validateSearch: mapSearchSchema,
  component: MapPage,
});
