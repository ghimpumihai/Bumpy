import { Helmet } from "react-helmet-async";

import { MapView } from "@/views/map";

/** Full-screen page: the map fills the viewport, so it skips PageWrapper on purpose. */
export function MapPage() {
  return (
    <>
      <Helmet>
        <title>Map · Bumpy</title>
      </Helmet>
      <MapView />
    </>
  );
}
