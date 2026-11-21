import { useEffect } from "react";

import { useMapState } from "@/components/map/map-context";

interface StreetFinderProps {
  /** Centre of the selected segment; nothing is looked up while undefined. */
  center: { lon: number; lat: number } | undefined;
  onFound: (name: string | undefined) => void;
}

/** Reads the street name from the road labels the base map has already drawn (no extra network call). */
export function StreetFinder({ center, onFound }: StreetFinderProps) {
  const state = useMapState();
  const map = state?.map;
  const lon = center?.lon;
  const lat = center?.lat;
  useEffect(() => {
    if (!map || lon === undefined || lat === undefined) {
      onFound(undefined);
      return;
    }
    const find = () => {
      const point = map.project([lon, lat]);
      const box: [[number, number], [number, number]] = [[point.x - 12, point.y - 12], [point.x + 12, point.y + 12]];
      const road = map.queryRenderedFeatures(box).find((feature) => feature.sourceLayer === "transportation_name" && feature.properties?.name);
      onFound(road ? String(road.properties.name) : undefined);
    };
    onFound(undefined);
    map.once("idle", find);
    return () => void map.off("idle", find);
  }, [map, lon, lat, onFound]);
  return null;
}
