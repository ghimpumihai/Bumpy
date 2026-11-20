import type { Map as MapLibreMap } from "maplibre-gl";
import { createContext, useContext } from "react";

export interface MapState {
  map: MapLibreMap;
  /** Increments whenever a style finished loading; a new style drops every source and layer. */
  styleGeneration: number;
}

export const MapContext = createContext<MapState | null>(null);

/** The MapLibre instance of the surrounding `MapCanvas`, available once its style is parsed. */
export function useMapState(): MapState | null {
  return useContext(MapContext);
}
