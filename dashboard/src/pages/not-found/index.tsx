import { Link } from "@tanstack/react-router";
import { Helmet } from "react-helmet-async";

import { PageWrapper } from "@/components/page-wrapper";
import { Button } from "@/components/ui/button";

export function NotFoundPage() {
  return (
    <>
      <Helmet>
        <title>Not found · Bumpy</title>
      </Helmet>
      <PageWrapper title="Page not found" description="This page does not exist.">
        <div>
          <Button asChild>
            <Link to="/live">Back to the live view</Link>
          </Button>
        </div>
      </PageWrapper>
    </>
  );
}
