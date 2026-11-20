import { sessionsApi } from "@/api/sessions";
import { EventsLayer } from "@/components/map/events-layer";
import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { MapCanvas } from "@/components/map/map-canvas";
import { MapLegend } from "@/components/map/map-legend";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { Position } from "@/types/common";
import { boundsOf } from "@/utils/geo";
import { stepColorExpression } from "@/utils/scale";

import { SPEED_BANDS, TRACK_EVENTS_SOURCE_ID, TRACK_LINE_WIDTH_PX, TRACK_SOURCE_ID } from "../utils/constants";
import { trackPieces } from "../utils/track";

const COLOR_VARS = ["--scale-1", "--scale-2", "--scale-3", "--scale-4", "--scale-5", "--scale-none"] as const;

interface TrackMapProps {
  sessionId: string;
  isLive: boolean;
}

export function TrackMap({ sessionId, isLive }: TrackMapProps) {
  const track = sessionsApi.useSessionTrack(sessionId, isLive);
  const events = sessionsApi.useSessionEvents(sessionId, isLive);
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
      <MapCanvas ariaLabel="Map of this trip coloured by speed, with detected events" className="absolute inset-0" bounds={bounds} boundsKey={bounds ? sessionId : undefined}>
        {track.data && <GeoJsonLayer id={TRACK_SOURCE_ID} data={trackPieces(track.data)} layers={layers} />}
        {events.data && <EventsLayer id={TRACK_EVENTS_SOURCE_ID} data={events.data} />}
      </MapCanvas>
      <MapLegend
        className="absolute bottom-8 left-3"
        title="Speed"
        bands={SPEED_BANDS}
        footnote={track.data ? `First and last ${track.data.properties.trimmedM} m hidden for privacy. Dots: detected events.` : undefined}
      />
    </div>
  );
}
