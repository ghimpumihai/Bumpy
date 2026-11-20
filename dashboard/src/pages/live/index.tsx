import { Helmet } from "react-helmet-async";

import { LiveView } from "@/views/live";

/** Full-screen page (map + side panel), so it skips PageWrapper on purpose. */
export function LivePage() {
  return (
    <>
      <Helmet>
        <title>Live · Road &amp; Ride</title>
      </Helmet>
      <LiveView />
    </>
  );
}
