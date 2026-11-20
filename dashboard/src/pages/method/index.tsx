import { Helmet } from "react-helmet-async";

import { PageWrapper } from "@/components/page-wrapper";
import { MethodView } from "@/views/method";

export function MethodPage() {
  return (
    <>
      <Helmet>
        <title>Method · Road &amp; Ride</title>
      </Helmet>
      <PageWrapper
        title="How it works"
        description="Road quality and motion sickness come from the same motion signal in different frequency bands, measured live from phones in cars, buses and trams. The roughest road is not necessarily the one that makes people sick."
      >
        <MethodView />
      </PageWrapper>
    </>
  );
}
