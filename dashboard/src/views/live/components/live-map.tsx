import { Marker } from "maplibre-gl";
import { useEffect, useRef, useState } from "react";

import { sessionsApi } from "@/api/sessions";
import { EventsLayer } from "@/components/map/events-layer";
import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { MAP_STYLE_DARK_URL } from "@/constants/map";
import { MapCanvas } from "@/components/map/map-canvas";
import { useMapState } from "@/components/map/map-context";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { LiveDevice } from "@/types/live";
import type { Position } from "@/types/common";
import { boundsOf } from "@/utils/geo";
import type { RoadEventCollection } from "@/types/sessions";

import {
  LIVE_FOCUS_MS,
  LIVE_FOCUS_ZOOM,
  LIVE_PING_GROWTH_PX,
  LIVE_PING_MS,
  LIVE_TRACK_GLOW_PX,
  LIVE_TRACK_WIDTH_PX,
  LIVE_TRACKS_SOURCE_ID,
} from "../utils/constants";
import { EMPTY_PINGS, livePings, liveTrails, type LivePing } from "../utils/geojson";
import { mergeTail } from "../utils/tail";
import { useLiveAnimation } from "../utils/use-live-animation";

const COLOR_VARS = ["--heat-low", "--event-pothole", "--event-speed-bump", "--event-rail-joint"] as const;
const PING_LAYER_ID = "live-pings-ring";
const PING_SOURCE_ID = "live-pings";
/** Potholes and speed bumps detected so far on a streaming trip; a detection that arrives while you watch sends a ping. */
function LiveEvents({ device, onDetect }: { device: LiveDevice; onDetect: (events: RoadEventCollection) => void }) {
  const events = sessionsApi.useSessionEvents({
    sessionId: device.sessionId,
    status: device.sessionStatus,
    startedAt: device.updatedAt,
    endedAt: null,
    durationS: 0,
  });
  const known = useRef<Set<string> | null>(null);
  const data = events.data;
  useEffect(() => {
    if (!data) return;
    // The first answer is history: no pings for events that were already there.
    if (known.current === null) {
      known.current = new Set(data.features.map((feature) => feature.properties.id));
      return;
    }
    const fresh = data.features.filter((feature) => !known.current?.has(feature.properties.id));
    for (const feature of fresh) known.current.add(feature.properties.id);
    if (fresh.length > 0) onDetect({ ...data, features: fresh });
  }, [data, onDetect]);
  return data ? <EventsLayer id={`live-events-${device.sessionId}`} data={data} /> : null;
}

/** One DOM marker per vehicle, moved every frame; it dims when the phone has gone quiet. */
function VehicleMarkers({ positions, stale }: { positions: Record<string, Position>; stale: ReadonlySet<string> }) {
  const map = useMapState()?.map ?? null;
  const markers = useRef(new Map<string, { marker: Marker; element: HTMLDivElement }>());
  useEffect(() => {
    if (!map) return;
    const live = markers.current;
    for (const [id, position] of Object.entries(positions)) {
      let entry = live.get(id);
      if (!entry) {
        const element = document.createElement("div");
        element.className = "vehicle-marker";
        element.appendChild(document.createElement("span"));
        entry = { marker: new Marker({ element }).setLngLat(position).addTo(map), element };
        live.set(id, entry);
      }
      entry.marker.setLngLat(position);
      entry.element.dataset.stale = String(stale.has(id));
    }
    for (const [id, entry] of live) {
      if (!(id in positions)) {
        entry.marker.remove();
        live.delete(id);
      }
    }
  });
  useEffect(() => {
    const live = markers.current;
    return () => {
      for (const entry of live.values()) entry.marker.remove();
      live.clear();
    };
  }, [map]);
  return null;
}

/** Glides the camera to the vehicle whose card was picked: out a little, then in, like switching character. */
function FocusCamera({ device, nonce }: { device: LiveDevice | undefined; nonce: number }) {
  const map = useMapState()?.map ?? null;
  const target = useRef(device);
  useEffect(() => {
    target.current = device;
  });
  useEffect(() => {
    const device = target.current;
    if (!map || nonce === 0 || !device) return;
    map.flyTo({ center: [device.lon, device.lat], zoom: Math.max(map.getZoom(), LIVE_FOCUS_ZOOM), duration: LIVE_FOCUS_MS, curve: 1.2, essential: false });
  }, [map, nonce]);
  return null;
}

interface LiveMapProps {
  devices: LiveDevice[];
  /** Trips whose phone has gone quiet: their marker dims and stops breathing. */
  stale: ReadonlySet<string>;
  /** The vehicle to fly to, and a counter that changes each time one is picked. */
  focus: { sessionId: string | undefined; nonce: number };
}

export function LiveMap({ devices, stale, focus }: LiveMapProps) {
  const [pings, setPings] = useState<LivePing[]>([]);
  const addPings = (events: RoadEventCollection) => {
    const startedAt = performance.now();
    setPings((previous) => [
      ...previous.filter((ping) => startedAt - ping.startedAt < LIVE_PING_MS),
      ...events.features.map((feature) => ({ key: feature.properties.id, position: feature.geometry.coordinates as Position, type: feature.properties.type, startedAt })),
    ]);
  };
  const colors = useThemeColors(COLOR_VARS);
  const [tails, setTails] = useState<Record<string, Position[][]>>({});
  const [seen, setSeen] = useState(devices);
  if (seen !== devices) {
    setSeen(devices);
    setTails((previous) => Object.fromEntries(devices.map((device) => [device.sessionId, mergeTail(previous[device.sessionId] ?? [], device.track)])));
  }
  const { trails, heads, now } = useLiveAnimation(tails);
  const positions: Record<string, Position> = Object.fromEntries(
    devices.map((device) => [device.sessionId, heads[device.sessionId] ?? ([device.lon, device.lat] as Position)]),
  );
  const points: Position[] = devices.flatMap((device) => [...(tails[device.sessionId]?.flat() ?? device.track), [device.lon, device.lat] as Position]);
  const bounds = boundsOf(points);
  // Re-fit only when the set of devices changes, so the map doesn't jump on every 2 s poll.
  const boundsKey = devices.map((device) => device.deviceId).sort().join(",");

  // Same look as the heat map: a thin line in the ramp with a soft glow.
  const trackLayers: SourceLayer[] = [
    {
      id: `${LIVE_TRACKS_SOURCE_ID}-glow`,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": colors["--heat-low"], "line-width": LIVE_TRACK_GLOW_PX, "line-blur": LIVE_TRACK_GLOW_PX * 0.8, "line-opacity": 0.4 },
    },
    {
      id: `${LIVE_TRACKS_SOURCE_ID}-line`,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": colors["--heat-low"], "line-width": LIVE_TRACK_WIDTH_PX, "line-opacity": 0.95 },
    },
  ];
  const pingLayers: SourceLayer[] = [
    {
      id: PING_LAYER_ID,
      type: "circle",
      paint: {
        "circle-radius": ["+", 4, ["*", LIVE_PING_GROWTH_PX, ["-", 1, ["^", ["-", 1, ["get", "age"]], 2]]]],
        "circle-color": "rgba(0, 0, 0, 0)",
        "circle-stroke-width": 1.5,
        "circle-stroke-color": ["match", ["get", "type"], "pothole", colors["--event-pothole"], "speed_bump", colors["--event-speed-bump"], colors["--event-rail-joint"]],
        "circle-stroke-opacity": ["*", 0.7, ["-", 1, ["get", "age"]]],
      },
    },
  ];
  return (
    <MapCanvas styleUrl={MAP_STYLE_DARK_URL} ariaLabel="Live positions of the phones that are streaming" className="absolute inset-0" bounds={bounds} boundsKey={bounds ? boundsKey : undefined}>
      <GeoJsonLayer id={LIVE_TRACKS_SOURCE_ID} data={liveTrails(trails)} layers={trackLayers} />
      {devices.map((device) => (
        <LiveEvents key={device.sessionId} device={device} onDetect={addPings} />
      ))}
      <GeoJsonLayer id={PING_SOURCE_ID} data={pings.length === 0 ? EMPTY_PINGS : livePings(pings, now, LIVE_PING_MS)} layers={pingLayers} />
      <VehicleMarkers positions={positions} stale={stale} />
      <FocusCamera device={devices.find((device) => device.sessionId === focus.sessionId)} nonce={focus.nonce} />
    </MapCanvas>
  );
}
