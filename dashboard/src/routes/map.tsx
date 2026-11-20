import { createFileRoute } from "@tanstack/react-router";

import { MapPage } from "@/pages/map";
import { mapSearchSchema } from "@/views/map/schema";

export const Route = createFileRoute("/map")({
  validateSearch: mapSearchSchema,
  component: MapPage,
});
