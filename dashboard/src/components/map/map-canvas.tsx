import type { StyleSpecification } from "maplibre-gl";
import { useEffect, useRef, useState, type ReactNode } from "react";

import {
  DEFAULT_MAP_CENTER,
  DEFAULT_MAP_ZOOM,
  FIT_BOUNDS_MAX_ZOOM,
  FIT_BOUNDS_PADDING_PX,
  MAP_STYLE_URL,
} from "@/constants/map";
import { MapLibreMap, NavigationControl, ScaleControl } from "@/lib/maplibre";
import { cn } from "@/lib/utils";
import type { Position } from "@/utils/geo";

import { MapContext, type MapState } from "./map-context";

/**
 * Used when the OpenFreeMap tiles cannot be loaded (bad Wi-Fi in the presentation room, plan 02 §17):
 * our own data layers still render on a plain background.
 */
const FALLBACK_STYLE: StyleSpecification = {
  version: 8,
  sources: {},
  layers: [{ id: "background", type: "background", paint: { "background-color": "#eef0f2" } }],
};

const isNetworkError = (error: unknown) =>
  error instanceof Error && (error.name === "AJAXError" || /fetch|network|load/i.test(error.message));

interface MapCanvasProps {
  /** Accessible description of what the map shows. */
  ariaLabel: string;
  className?: string;
  /** Fit the view to these bounds whenever `boundsKey` changes. */
  bounds?: [Position, Position] | null;
  boundsKey?: string;
  children?: ReactNode;
}

export function MapCanvas({ ariaLabel, className, bounds, boundsKey, children }: MapCanvasProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<MapState | null>(null);
  const map = state?.map ?? null;
  const [basemapFailed, setBasemapFailed] = useState(false);

  useEffect(() => {
    if (!containerRef.current) return;
    const instance = new MapLibreMap({
      container: containerRef.current,
      style: MAP_STYLE_URL,
      center: DEFAULT_MAP_CENTER,
      zoom: DEFAULT_MAP_ZOOM,
      attributionControl: { compact: true },
    });
    instance.addControl(new NavigationControl({ visualizePitch: false }), "top-right");
    instance.addControl(new ScaleControl({ unit: "metric" }), "bottom-right");

    let styleReady = false;
    // `style.load` (style parsed) instead of `load` (every tile and sprite fetched): our data must not
    // wait for the base map on a slow network.
    instance.on("style.load", () => {
      styleReady = true;
      setState((previous) => ({ map: instance, styleGeneration: (previous?.styleGeneration ?? 0) + 1 }));
    });
    // The style itself could not be fetched: the base map is unreachable, so draw on a plain background.
    instance.on("error", (event) => {
      if (styleReady || !isNetworkError(event.error)) return;
      styleReady = true;
      setBasemapFailed(true);
      instance.setStyle(FALLBACK_STYLE);
    });
    return () => {
      setState(null);
      instance.remove();
    };
  }, []);

  useEffect(() => {
    if (!map || !bounds) return;
    map.fitBounds(bounds, { padding: FIT_BOUNDS_PADDING_PX, maxZoom: FIT_BOUNDS_MAX_ZOOM, duration: 600 });
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
