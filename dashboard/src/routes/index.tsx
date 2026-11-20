import { createFileRoute, redirect } from "@tanstack/react-router";

/** The live view is the main screen (plan 02 §5): the vehicle moving while the trip is driven. */
export const Route = createFileRoute("/")({
  beforeLoad: () => {
    throw redirect({ to: "/live", replace: true });
  },
});
