import type { StyleSpecification } from "maplibre-gl";
import { useEffect, useRef, useState, type ReactNode } from "react";

import {
  BASEMAP_STYLE_TIMEOUT_MS,
  DEFAULT_MAP_CENTER,
  DEFAULT_MAP_ZOOM,
  FIT_BOUNDS_DURATION_MS,
  FIT_BOUNDS_MAX_ZOOM,
  FIT_BOUNDS_PADDING_PX,
  MAP_STYLE_DARK_URL,
  MAP_STYLE_URL,
} from "@/constants/map";
import { MapLibreMap, NavigationControl, ScaleControl } from "@/lib/maplibre";
import { cn } from "@/lib/utils";
import type { MapState } from "@/types/map";
import type { Position } from "@/types/common";
import { useThemeColors } from "@/hooks/use-theme-colors";
import { readCssColor } from "@/utils/css-color";

import { MapContext } from "./map-context";
import { quietDarkBasemap } from "./quiet-basemap";

/**
 * Used when the OpenFreeMap style cannot be loaded (bad Wi-Fi in the presentation room, plan 02 §17):
 * our own data layers still render on a plain, theme-coloured background.
 */
const FALLBACK_COLOR_VARS = ["--muted"] as const;
const FALLBACK_BACKGROUND_LAYER_ID = "background";

function fallbackStyle(): StyleSpecification {
  return {
    version: 8,
    sources: {},
    layers: [{ id: FALLBACK_BACKGROUND_LAYER_ID, type: "background", paint: { "background-color": readCssColor("--muted") } }],
  };
}

const isNetworkError = (error: unknown) =>
  error instanceof Error && (error.name === "AJAXError" || /fetch|network|load/i.test(error.message));

interface MapCanvasProps {
  /** Accessible description of what the map shows. */
  ariaLabel: string;
  className?: string;
  /** Fit the view to these bounds whenever `boundsKey` changes. */
  bounds?: [Position, Position] | null;
  boundsKey?: string;
  /** Padding for the fit: leave room for a panel that covers part of the map. */
  fitPadding?: { top: number; right: number; bottom: number; left: number };
  /** Base map style; the light OpenFreeMap one by default. */
  styleUrl?: string;
  children?: ReactNode;
}

export function MapCanvas({ ariaLabel, className, bounds, boundsKey, fitPadding, styleUrl = MAP_STYLE_URL, children }: MapCanvasProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<MapState | null>(null);
  const map = state?.map ?? null;
  const [basemapFailed, setBasemapFailed] = useState(false);
  const fallbackColors = useThemeColors(FALLBACK_COLOR_VARS);

  useEffect(() => {
    if (!containerRef.current) return;
    const instance = new MapLibreMap({
      container: containerRef.current,
      style: styleUrl,
      center: DEFAULT_MAP_CENTER,
      zoom: DEFAULT_MAP_ZOOM,
      attributionControl: { compact: true },
    });
    instance.addControl(new NavigationControl({ visualizePitch: false }), "top-right");
    instance.addControl(new ScaleControl({ unit: "metric" }), "bottom-right");

    let styleReady = false;
    const switchToFallback = () => {
      if (styleReady) return;
      styleReady = true;
      setBasemapFailed(true);
      instance.setStyle(fallbackStyle());
    };
    // `style.load` (style parsed) instead of `load` (every tile and sprite fetched): our data must not
    // wait for the base map on a slow network.
    instance.on("style.load", () => {
      styleReady = true;
      if (styleUrl === MAP_STYLE_DARK_URL) quietDarkBasemap(instance);
      window.clearTimeout(styleTimeout);
      setState((previous) => ({ map: instance, styleGeneration: (previous?.styleGeneration ?? 0) + 1 }));
    });
    // The style could not be fetched, or the request hangs (a network that accepts but stalls).
    const styleTimeout = window.setTimeout(switchToFallback, BASEMAP_STYLE_TIMEOUT_MS);
    instance.on("error", (event) => {
      if (!styleReady && isNetworkError(event.error)) {
        switchToFallback();
        return;
      }
      // With a listener attached MapLibre no longer logs errors itself (bad expressions, failed tiles).
      console.error(event.error);
    });
    return () => {
      window.clearTimeout(styleTimeout);
      setState(null);
      instance.remove();
    };
  }, [styleUrl]);

  // The offline background follows theme changes like the data layers do.
  useEffect(() => {
    if (!map || !basemapFailed || !map.getLayer(FALLBACK_BACKGROUND_LAYER_ID)) return;
    map.setPaintProperty(FALLBACK_BACKGROUND_LAYER_ID, "background-color", fallbackColors["--muted"]);
  }, [map, basemapFailed, fallbackColors]);

  useEffect(() => {
    if (!map || !bounds) return;
    map.fitBounds(bounds, { padding: fitPadding ?? FIT_BOUNDS_PADDING_PX, maxZoom: FIT_BOUNDS_MAX_ZOOM, duration: FIT_BOUNDS_DURATION_MS });
    // boundsKey decides when to re-fit, so live updates don't fight the user's panning.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, boundsKey]);

  return (
    <div className={cn("relative overflow-hidden", className)}>
      {/* size-full, not absolute inset-0: MapLibre forces `position: relative` on its container. */}
      <div ref={containerRef} className="size-full" role="region" aria-label={ariaLabel} />
      {basemapFailed && (
        <p className="absolute bottom-2 left-1/2 -translate-x-1/2 rounded-md bg-card/90 px-2 py-1 text-xs text-muted-foreground shadow-sm">
          Base map unavailable (offline) — data layers still shown.
        </p>
      )}
      <MapContext.Provider value={state}>{children}</MapContext.Provider>
    </div>
  );
}
