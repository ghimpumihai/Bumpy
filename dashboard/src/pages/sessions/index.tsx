import { Helmet } from "react-helmet-async";

import { PageWrapper } from "@/components/page-wrapper";
import { SessionsView } from "@/views/sessions";

export function SessionsPage() {
  return (
    <>
      <Helmet>
        <title>Sessions · Bumpy</title>
      </Helmet>
      <PageWrapper title="Sessions">
        <SessionsView />
      </PageWrapper>
    </>
  );
}
