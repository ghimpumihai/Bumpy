import { Helmet } from "react-helmet-async";

import { SessionView } from "@/views/session";

export function SessionPage() {
  return (
    <>
      <Helmet>
        <title>Session · Bumpy</title>
      </Helmet>
      <SessionView />
    </>
  );
}
