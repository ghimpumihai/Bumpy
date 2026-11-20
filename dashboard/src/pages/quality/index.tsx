import { Helmet } from "react-helmet-async";

import { PageWrapper } from "@/components/page-wrapper";
import { QualityView } from "@/views/quality";

export function QualityPage() {
  return (
    <>
      <Helmet>
        <title>Data quality · Road &amp; Ride</title>
      </Helmet>
      <PageWrapper
        title="Data quality"
        description="Some recordings will be bad (hand-held phone, phone moved, poor GPS). The pipeline measures every session and keeps bad ones out of the aggregated map automatically."
      >
        <QualityView />
      </PageWrapper>
    </>
  );
}
