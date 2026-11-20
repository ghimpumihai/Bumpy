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
        description="Every trip. Trips are streamed from the phone while driving and count in the aggregated map once they are finalized; laptop uploads are the fallback for trips that never reached the cloud, and replays never count."
      >
        <SessionsView />
      </PageWrapper>
    </>
  );
}
