import { Helmet } from "react-helmet-async";

import { SessionView } from "@/views/session";

export function SessionPage() {
  return (
    <>
      <Helmet>
        <title>Session · Road &amp; Ride</title>
      </Helmet>
      <SessionView />
    </>
  );
}
