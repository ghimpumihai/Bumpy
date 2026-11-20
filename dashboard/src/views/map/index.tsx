import { useNavigate, useSearch } from "@tanstack/react-router";

import { eventsApi } from "@/api/events";
import { overviewApi } from "@/api/overview";
import { segmentsApi } from "@/api/segments";
import { EventsLayer, eventsCircleLayerId } from "@/components/map/events-layer";
import { MapCanvas } from "@/components/map/map-canvas";
import { MapLegend } from "@/components/map/map-legend";
import { ErrorAlert } from "@/components/error-alert";
import type { Position } from "@/types/common";
import { boundsOf } from "@/utils/geo";

import { MapControls } from "./components/map-controls";
import { OverviewStrip } from "./components/overview-strip";
import { SegmentHighlights } from "./components/segment-highlights";
import { SegmentPanel } from "./components/segment-panel";
import { SegmentsLayer } from "./components/segments-layer";
import type { MapSearch } from "./schema";
import { EVENTS_SOURCE_ID } from "./utils/constants";
import { metricScale } from "./utils/metric";

export function MapView() {
  const search = useSearch({ from: "/map" });
  const navigate = useNavigate({ from: "/map" });
  const overview = overviewApi.useOverview();
  const segments = segmentsApi.useSegments(search.vehicle);
  const events = eventsApi.useEvents(search.vehicle);
  const scale = metricScale(search.metric, overview.data?.aggregation.method);

  const update = (patch: Partial<MapSearch>) => void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: true });

  // Fit to the selected segment (from the map or the keyboard list), otherwise to every segment.
  const selected = segments.data?.features.find((f) => f.properties.h3 === search.segment);
  const corners: Position[] = (selected ? [selected] : (segments.data?.features ?? [])).flatMap((f) => f.geometry.coordinates[0] as Position[]);
  const bounds = boundsOf(corners);

  return (
    <div className="relative flex-1">
      <MapCanvas
        ariaLabel={`Map of road segments coloured by ${scale.title.toLowerCase()}`}
        className="absolute inset-0"
        bounds={bounds}
        boundsKey={bounds ? (selected?.properties.h3 ?? "all") : undefined}
      >
        {segments.data && (
          <SegmentsLayer
            data={segments.data}
            beforeId={eventsCircleLayerId(EVENTS_SOURCE_ID)}
            scale={scale} selectedH3={search.segment} onSelect={(h3) => update({ segment: h3 })} />
        )}
        {search.events && events.data && <EventsLayer id={EVENTS_SOURCE_ID} data={events.data} />}
      </MapCanvas>
      <div className="pointer-events-none absolute inset-x-3 top-3 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="pointer-events-auto vertical max-w-sm gap-3">
          <MapControls search={search} onChange={update} />
          {segments.data && (
            <SegmentHighlights data={segments.data} scale={scale} selectedH3={search.segment} onSelect={(h3) => update({ segment: h3 })} />
          )}
          {segments.error && <ErrorAlert title="Road segments" error={segments.error} onRetry={() => void segments.refetch()} />}
          {search.events && events.error && <ErrorAlert title="Detected events" error={events.error} onRetry={() => void events.refetch()} />}
        </div>
        <div className="pointer-events-auto hidden sm:mr-12 sm:block">
          <OverviewStrip />
        </div>
      </div>
      <div className="pointer-events-none absolute bottom-8 left-3">
        <MapLegend
          className="pointer-events-auto"
          title={scale.title}
          bands={scale.bands}
          missingLabel="No data for this metric"
          footnote={`${scale.footnote} Red outline: crowd-confirmed pothole.`}
        />
      </div>
      <SegmentPanel h3={search.segment} onClose={() => update({ segment: undefined })} />
    </div>
  );
}
