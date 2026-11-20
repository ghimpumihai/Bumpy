import { createFileRoute } from "@tanstack/react-router";

import { MethodPage } from "@/pages/method";

export const Route = createFileRoute("/method")({
  component: MethodPage,
});
