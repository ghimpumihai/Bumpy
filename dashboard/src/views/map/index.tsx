import { useNavigate, useSearch } from "@tanstack/react-router";
import { useMemo, useState } from "react";

import { useNarrowScreen } from "@/hooks/use-narrow-screen";

import { eventsApi } from "@/api/events";
import { segmentsApi } from "@/api/segments";
import { EventsLayer, eventsCircleLayerId } from "@/components/map/events-layer";
import { HeatCanvasLayer } from "@/components/map/heat-canvas-layer";
import { MapCanvas } from "@/components/map/map-canvas";
import { MAP_STYLE_DARK_URL } from "@/constants/map";
import { ErrorAlert } from "@/components/error-alert";
import type { Position } from "@/types/common";
import { VehicleFilter } from "@/types/segments";
import { boundsOf } from "@/utils/geo";

import { HeatLegend } from "./components/heat-legend";
import { OverviewStrip } from "./components/overview-strip";
import { ReplayLayer } from "./components/replay-layer";
import { SegmentHighlights } from "./components/segment-highlights";
import { StreetFinder } from "./components/street-finder";
import { SegmentPanel } from "./components/segment-panel";
import { SegmentsLayer } from "./components/segments-layer";
import { TripReplayControls } from "./components/trip-replay-controls";
import type { MapSearch } from "./schema";
import { EVENTS_SOURCE_ID, REPLAY_GLOW_LAYER_ID, REPLAY_LINE_LAYER_ID, SEGMENT_HIT_LAYER_ID, SELECTED_SEGMENT_LAYER_ID } from "./utils/constants";
import { useReplayedEvents } from "./utils/use-replayed-events";
import { useTripReplay } from "./utils/use-trip-replay";

/** Width of the road panel on a desktop screen (Tailwind `max-w-xl`) and its share of the height on a phone. */
const PANEL_WIDTH_PX = 576;
const PANEL_SHARE_NARROW = 0.55;

/** Drawn above the heat image: the trip being replayed, the click targets, the selection ring and the event dots. */
const HEAT_ABOVE_LAYERS = [REPLAY_GLOW_LAYER_ID, REPLAY_LINE_LAYER_ID, SEGMENT_HIT_LAYER_ID, SELECTED_SEGMENT_LAYER_ID, eventsCircleLayerId(EVENTS_SOURCE_ID)];

export function MapView() {
  const [street, setStreet] = useState<string>();
  const search = useSearch({ from: "/map" });
  const navigate = useNavigate({ from: "/map" });
    const segments = segmentsApi.useSegments(VehicleFilter.ALL);
  const heat = segmentsApi.useHeat();
  const events = eventsApi.useEvents(VehicleFilter.ALL);
  const replay = useTripReplay(search.speed);
  const shownEvents = useReplayedEvents(events.data, replay);

  const update = (patch: Partial<MapSearch>) => void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: true });

  // Fit to the selected segment (from the map or the keyboard list), otherwise to every segment.
  const selected = segments.data?.features.find((f) => f.properties.h3 === search.segment);
  const selectedCenter = useMemo(() => {
    const ring = selected?.geometry.coordinates[0];
    return ring ? { lon: ring.reduce((sum, p) => sum + p[0], 0) / ring.length, lat: ring.reduce((sum, p) => sum + p[1], 0) / ring.length } : undefined;
  }, [selected]);
  // The detail panel covers the right of the screen (the bottom on a phone): zoom to the road beside it, not under it.
  const narrow = useNarrowScreen();
  const base = 48;
  const fitPadding = !selected
    ? undefined
    : narrow
      ? { top: base, left: base, right: base, bottom: Math.round(window.innerHeight * PANEL_SHARE_NARROW) + base }
      : { top: base, left: base, bottom: base, right: PANEL_WIDTH_PX + base };
  const corners: Position[] = (selected ? [selected] : (segments.data?.features ?? [])).flatMap((f) => f.geometry.coordinates[0] as Position[]);
  const bounds = boundsOf(corners);

  return (
    <div className="relative flex-1">
      <MapCanvas
        ariaLabel={"Heat map of trips per road segment"}
        className="absolute inset-0"
        bounds={bounds}
        boundsKey={bounds ? (selected?.properties.h3 ?? "all") : undefined}
        fitPadding={fitPadding}
        styleUrl={MAP_STYLE_DARK_URL}
      >
        {heat.data && (
          <HeatCanvasLayer
            id="heat"
            data={replay.active ? replay.done : heat.data}
            scaleData={replay.active ? heat.data : undefined}
            keepAbove={HEAT_ABOVE_LAYERS}
          />
        )}
        {replay.active && <ReplayLayer frame={replay.frame} beforeId={SEGMENT_HIT_LAYER_ID} />}
        {segments.data && (
          <SegmentsLayer
            data={segments.data}
            beforeId={eventsCircleLayerId(EVENTS_SOURCE_ID)}
            selectedH3={search.segment} onSelect={(h3) => update({ segment: h3 })} />
        )}
        <StreetFinder center={selectedCenter} onFound={setStreet} />
        {search.events && shownEvents && <EventsLayer id={EVENTS_SOURCE_ID} data={shownEvents} />}
      </MapCanvas>
      <div className="pointer-events-none absolute top-[4.5rem] right-3 left-3 vertical items-end gap-2 sm:top-3 sm:right-14 sm:left-auto">
        <div className="pointer-events-auto hidden sm:block">
          <OverviewStrip />
        </div>
        {segments.error && (
          <div className="pointer-events-auto w-full max-w-sm">
            <ErrorAlert title="Road segments" error={segments.error} onRetry={() => void segments.refetch()} />
          </div>
        )}
        {search.events && events.error && (
          <div className="pointer-events-auto w-full max-w-sm">
            <ErrorAlert title="Detected events" error={events.error} onRetry={() => void events.refetch()} />
          </div>
        )}
      </div>
      <div className="pointer-events-none absolute bottom-8 left-3">
        <HeatLegend
          className="pointer-events-auto"
          replay={<TripReplayControls replay={replay} disabled={!heat.data} />}
          showEvents={search.events}
          onShowEventsChange={(show) => update({ events: show })}
        />
      </div>
      {segments.data && (
        <div className="pointer-events-none absolute right-3 bottom-20">
          <div className="pointer-events-auto">
            <SegmentHighlights data={segments.data} selectedH3={search.segment} onSelect={(h3) => update({ segment: h3 })} />
          </div>
        </div>
      )}
      <SegmentPanel h3={search.segment} street={street} narrow={narrow} onClose={() => update({ segment: undefined })} />
    </div>
  );
}
