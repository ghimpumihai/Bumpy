import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { MapCanvas } from "@/components/map/map-canvas";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { LiveDevice } from "@/types/live";
import type { Position } from "@/types/common";
import { boundsOf } from "@/utils/geo";

import {
  LIVE_DEVICES_SOURCE_ID,
  LIVE_HALO_OPACITY,
  LIVE_HALO_SCALE,
  LIVE_MARKER_RADIUS_PX,
  LIVE_MARKER_STROKE_PX,
  LIVE_TRACK_OPACITY,
  LIVE_TRACK_WIDTH_PX,
  LIVE_TRACKS_SOURCE_ID,
} from "../utils/constants";
import { livePositions, liveTracks } from "../utils/geojson";

const COLOR_VARS = ["--live", "--info", "--card", "--track"] as const;

export function LiveMap({ devices }: { devices: LiveDevice[] }) {
  const colors = useThemeColors(COLOR_VARS);
  const points: Position[] = devices.flatMap((device) => [...device.track, [device.lon, device.lat] as Position]);
  const bounds = boundsOf(points);
  // Re-fit only when the set of devices changes, so the map doesn't jump on every 2 s poll.
  const boundsKey = devices.map((device) => device.deviceId).sort().join(",");

  const trackLayers: SourceLayer[] = [
    {
      id: `${LIVE_TRACKS_SOURCE_ID}-line`,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": colors["--track"], "line-width": LIVE_TRACK_WIDTH_PX, "line-opacity": LIVE_TRACK_OPACITY },
    },
  ];
  const deviceLayers: SourceLayer[] = [
    {
      id: `${LIVE_DEVICES_SOURCE_ID}-halo`,
      type: "circle",
      paint: { "circle-radius": LIVE_MARKER_RADIUS_PX * LIVE_HALO_SCALE, "circle-color": colors["--live"], "circle-opacity": LIVE_HALO_OPACITY },
    },
    {
      id: `${LIVE_DEVICES_SOURCE_ID}-dot`,
      type: "circle",
      paint: {
        "circle-radius": LIVE_MARKER_RADIUS_PX,
        // Replays are blue, real phones red, matching their badges.
        "circle-color": ["match", ["get", "source"], "replay", colors["--info"], colors["--live"]],
        "circle-stroke-color": colors["--card"],
        "circle-stroke-width": LIVE_MARKER_STROKE_PX,
      },
    },
  ];
  return (
    <MapCanvas ariaLabel="Live positions of the phones that are streaming" className="absolute inset-0" bounds={bounds} boundsKey={bounds ? boundsKey : undefined}>
      <GeoJsonLayer id={LIVE_TRACKS_SOURCE_ID} data={liveTracks(devices)} layers={trackLayers} beforeId={`${LIVE_DEVICES_SOURCE_ID}-halo`} />
      <GeoJsonLayer id={LIVE_DEVICES_SOURCE_ID} data={livePositions(devices)} layers={deviceLayers} />
    </MapCanvas>
  );
}
