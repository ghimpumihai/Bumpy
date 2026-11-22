import type { FeatureCollection, MultiLineString } from "geojson";
import { useEffect } from "react";

import { useMapState } from "./map-context";
import { renderHeat } from "./heat-raster";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { Position } from "@/types/common";

const COLOR_VARS = ["--heat-low", "--heat-mid", "--heat"] as const;
/** Draw this far beyond the screen on every side, so small pans don't show an uncovered edge. */
const MARGIN = 0.5;
/** Less during a replay, which redraws after every trip: about a third of the pixels. */
const REPLAY_MARGIN = 0.1;
const MAX_DPR = 2;
const REDRAW_DELAY_MS = 60;

interface HeatCanvasLayerProps {
  id: string;
  data: FeatureCollection<MultiLineString>;
  /** During a replay: fit the colour scale to these trips instead of `data`. */
  scaleData?: FeatureCollection<MultiLineString>;
  /** Layers that must stay above the heat (the clickable segments, the event dots). */
  keepAbove?: string[];
}

/**
 * The heat map as an image laid over the map: redrawn from the trip lines whenever the view settles, so the colour
 * scale always fits what is on screen (see `renderHeat`). The image is a MapLibre canvas source, not a data layer.
 */
export function HeatCanvasLayer({ id, data, scaleData, keepAbove = [] }: HeatCanvasLayerProps) {
  const state = useMapState();
  const map = state?.map ?? null;
  const styleGeneration = state?.styleGeneration ?? 0;
  const colors = useThemeColors(COLOR_VARS);
  const ramp = [colors["--heat-low"], colors["--heat-mid"], colors["--heat"]];
  const rampKey = ramp.join("|");
  const aboveKey = keepAbove.join("|");

  useEffect(() => {
    if (!map) return;
    let timer = 0;
    let generation = 0;

    const draw = () => {
      if (!map.style) return;
      const dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
      const cssWidth = map.getContainer().clientWidth;
      const cssHeight = map.getContainer().clientHeight;
      const margin = scaleData ? REPLAY_MARGIN : MARGIN;
      const padX = cssWidth * margin;
      const padY = cssHeight * margin;
      const width = Math.round((cssWidth + 2 * padX) * dpr);
      const height = Math.round((cssHeight + 2 * padY) * dpr);
      const toPixel = ([lon, lat]: Position): Position => {
        const point = map.project([lon, lat]);
        return [(point.x + padX) * dpr, (point.y + padY) * dpr];
      };
      const zoom = map.getZoom();
      // Thin when zoomed out, thickening as you zoom in so the line fills the road it follows.
      const lineWidth = Math.min(9, Math.max(1.3, 1.3 + (zoom - 11) * 0.85)) * dpr;
      const toPixels = (trips: FeatureCollection<MultiLineString>) =>
        trips.features.map((feature) => feature.geometry.coordinates.map((line) => line.map((p) => toPixel(p as Position))));
      const canvas = renderHeat({ width, height, trips: toPixels(data), scaleTrips: scaleData && toPixels(scaleData), lineWidth, glow: lineWidth * 1.8, ramp: rampKey.split("|") });
      const corners = [
        map.unproject([-padX, -padY]),
        map.unproject([cssWidth + padX, -padY]),
        map.unproject([cssWidth + padX, cssHeight + padY]),
        map.unproject([-padX, cssHeight + padY]),
      ].map((c) => [c.lng, c.lat]) as [[number, number], [number, number], [number, number], [number, number]];

      // A fresh source each time: the simplest way to make the image update.
      if (map.getLayer(id)) map.removeLayer(id);
      if (map.getSource(id)) map.removeSource(id);
      map.addSource(id, { type: "canvas", canvas, coordinates: corners, animate: false });
      map.addLayer({ id, type: "raster", source: id, paint: { "raster-fade-duration": 0, "raster-resampling": "linear" } });
      for (const above of aboveKey ? aboveKey.split("|") : []) if (map.getLayer(above)) map.moveLayer(above);
    };

    const schedule = () => {
      window.clearTimeout(timer);
      const mine = ++generation;
      timer = window.setTimeout(() => mine === generation && draw(), REDRAW_DELAY_MS);
    };

    draw();
    map.on("moveend", schedule);
    return () => {
      window.clearTimeout(timer);
      generation++;
      map.off("moveend", schedule);
      if (!map.style) return;
      if (map.getLayer(id)) map.removeLayer(id);
      if (map.getSource(id)) map.removeSource(id);
    };
  }, [map, styleGeneration, id, data, scaleData, rampKey, aboveKey]);

  return null;
}
