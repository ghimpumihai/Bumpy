import type { FeatureCollection, MultiLineString } from "geojson";
import { Marker } from "maplibre-gl";
import { useEffect, useRef } from "react";

import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { useMapState } from "@/components/map/map-context";
import { useThemeColors } from "@/hooks/use-theme-colors";

import { REPLAY_GLOW_LAYER_ID, REPLAY_LINE_LAYER_ID, REPLAY_SOURCE_ID } from "../utils/constants";
import type { PlaybackFrame } from "../utils/track-playback";

const COLOR_VARS = ["--heat-low"] as const;
/** Same width as the heat lines (`HeatCanvasLayer`), so a finished trip doesn't jump when it joins the heat. */
const LINE_WIDTH = ["interpolate", ["linear"], ["zoom"], 11, 1.3, 20, 8.95];
const GLOW_WIDTH = ["interpolate", ["linear"], ["zoom"], 11, 5, 20, 34];

interface ReplayLayerProps {
  frame: PlaybackFrame | null;
  beforeId: string;
}

/** The trip being replayed: its line so far, and a marker at its head. */
export function ReplayLayer({ frame, beforeId }: ReplayLayerProps) {
  const colors = useThemeColors(COLOR_VARS);
  const data: FeatureCollection<MultiLineString> = {
    type: "FeatureCollection",
    features: frame ? [{ type: "Feature", geometry: { type: "MultiLineString", coordinates: frame.lines }, properties: {} }] : [],
  };
  const layers: SourceLayer[] = [
    {
      id: REPLAY_GLOW_LAYER_ID,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": colors["--heat-low"], "line-width": GLOW_WIDTH as never, "line-blur": GLOW_WIDTH as never, "line-opacity": 0.5 },
    },
    {
      id: REPLAY_LINE_LAYER_ID,
      type: "line",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": colors["--heat-low"], "line-width": LINE_WIDTH as never },
    },
  ];
  return (
    <>
      <GeoJsonLayer id={REPLAY_SOURCE_ID} data={data} layers={layers} beforeId={beforeId} />
      <ReplayMarker head={frame?.head} />
    </>
  );
}

function ReplayMarker({ head }: { head: PlaybackFrame["head"] | undefined }) {
  const map = useMapState()?.map ?? null;
  const marker = useRef<Marker | null>(null);
  useEffect(() => {
    if (!map || !head) {
      marker.current?.remove();
      marker.current = null;
      return;
    }
    if (marker.current) {
      marker.current.setLngLat(head);
      return;
    }
    const element = document.createElement("div");
    element.className = "vehicle-marker";
    element.appendChild(document.createElement("span"));
    marker.current = new Marker({ element }).setLngLat(head).addTo(map);
  }, [map, head]);
  useEffect(
    () => () => {
      marker.current?.remove();
      marker.current = null;
    },
    [map],
  );
  return null;
}
