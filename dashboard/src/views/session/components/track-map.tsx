import { sessionsApi } from "@/api/sessions";
import { MAP_STYLE_DARK_URL } from "@/constants/map";
import { ErrorAlert } from "@/components/error-alert";
import { EventsLayer, eventsCircleLayerId } from "@/components/map/events-layer";
import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { MapCanvas } from "@/components/map/map-canvas";
import { MapLegend } from "@/components/map/map-legend";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { Position } from "@/types/common";
import type { SessionSummary } from "@/types/sessions";
import { boundsOf } from "@/utils/geo";
import { stepColorExpression } from "@/utils/scale";

import { SPEED_BANDS, TRACK_EVENTS_SOURCE_ID, TRACK_LINE_WIDTH_PX, TRACK_SOURCE_ID } from "../utils/constants";
import { trackPieces } from "../utils/track";

const COLOR_VARS = ["--scale-1", "--scale-2", "--scale-3", "--scale-4", "--scale-5", "--scale-none"] as const;

interface TrackMapProps {
  session: SessionSummary;
}

export function TrackMap({ session }: TrackMapProps) {
  const track = sessionsApi.useSessionTrack(session);
  const events = sessionsApi.useSessionEvents(session);
  const colors = useThemeColors(COLOR_VARS);
  const bounds = track.data ? boundsOf(track.data.geometry.coordinates as Position[]) : null;
  const layers: SourceLayer[] = [
    {
      id: `${TRACK_SOURCE_ID}-line`,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        "line-width": TRACK_LINE_WIDTH_PX,
        "line-color": stepColorExpression(
          "speedKmh",
          SPEED_BANDS,
          SPEED_BANDS.map((band) => colors[band.colorVar as (typeof COLOR_VARS)[number]]),
          colors["--scale-none"],
        ) as never,
      },
    },
  ];
  return (
    <div className="relative h-96 overflow-hidden rounded-lg border">
      <MapCanvas styleUrl={MAP_STYLE_DARK_URL} ariaLabel="Map of this trip coloured by speed, with detected events" className="absolute inset-0" bounds={bounds} boundsKey={bounds ? session.sessionId : undefined}>
        {track.data && (
          <GeoJsonLayer id={TRACK_SOURCE_ID} data={trackPieces(track.data)} layers={layers} beforeId={eventsCircleLayerId(TRACK_EVENTS_SOURCE_ID)} />
        )}
        {events.data && <EventsLayer id={TRACK_EVENTS_SOURCE_ID} data={events.data} />}
      </MapCanvas>
      {(track.error || events.error) && (
        <div className="absolute inset-x-3 top-3 max-w-md">
          {track.error ? (
            <ErrorAlert title="The track" error={track.error} onRetry={() => void track.refetch()} />
          ) : (
            <ErrorAlert title="The detected events" error={events.error} onRetry={() => void events.refetch()} />
          )}
        </div>
      )}
      <MapLegend
        className="absolute bottom-8 left-3"
        title="Speed"
        bands={SPEED_BANDS}
        footnote={track.data ? "Dots: detected events." : undefined}
      />
    </div>
  );
}
