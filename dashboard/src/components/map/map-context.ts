import { createContext, useContext } from "react";

import type { MapState } from "@/types/map";

export const MapContext = createContext<MapState | null>(null);

/** The MapLibre instance of the surrounding `MapCanvas`, available once its style is parsed. */
export function useMapState(): MapState | null {
  return useContext(MapContext);
}
