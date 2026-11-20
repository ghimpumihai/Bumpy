import { Helmet } from "react-helmet-async";

import { PageWrapper } from "@/components/page-wrapper";
import { SessionsView } from "@/views/sessions";

export function SessionsPage() {
  return (
    <>
      <Helmet>
        <title>Sessions · Road &amp; Ride</title>
      </Helmet>
      <PageWrapper
        title="Sessions"
        description="Every recorded trip. Uploaded session folders are the main dataset; replays and live-only sessions are shown but never counted in the aggregated map."
      >
        <SessionsView />
      </PageWrapper>
    </>
  );
}
