import type { FeatureCollection, Point } from "geojson";
import type { MapGeoJSONFeature } from "maplibre-gl";
import { useMemo } from "react";

import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { SegmentCollection } from "@/types/segments";

import {
  SEGMENT_HIT_LAYER_ID,
  SEGMENT_HIT_RADIUS_PX,
  SEGMENT_INTERACTIVE_LAYERS,
  SEGMENTS_SOURCE_ID,
  SELECTED_OUTLINE_WIDTH_PX,
  SELECTED_SEGMENT_LAYER_ID,
} from "../utils/constants";

const COLOR_VARS = ["--foreground"] as const;

interface SegmentsLayerProps {
  data: SegmentCollection;
  /** Draw below this layer (the event dots), whatever order the requests finish in. */
  beforeId?: string;
  selectedH3: string | undefined;
  onSelect: (h3: string) => void;
}

/** One point per road segment, only for clicking and selecting: the cells themselves are never drawn. */
function centroids(data: SegmentCollection): FeatureCollection<Point, { h3: string; nSessions: number }> {
  return {
    type: "FeatureCollection",
    features: data.features.map((feature) => {
      const ring = feature.geometry.coordinates[0];
      const lon = ring.reduce((sum, p) => sum + p[0], 0) / ring.length;
      const lat = ring.reduce((sum, p) => sum + p[1], 0) / ring.length;
      return {
        type: "Feature",
        geometry: { type: "Point", coordinates: [lon, lat] },
        properties: { h3: feature.properties.h3, nSessions: feature.properties.nSessions },
      };
    }),
  };
}

export function SegmentsLayer({ data, beforeId, selectedH3, onSelect }: SegmentsLayerProps) {
  const colors = useThemeColors(COLOR_VARS);
  const points = useMemo(() => centroids(data), [data]);
  const layers: SourceLayer[] = [
    {
      id: SEGMENT_HIT_LAYER_ID,
      type: "circle",
      // Not exactly 0: a fully transparent circle is skipped by MapLibre and can no longer be clicked.
      paint: { "circle-radius": SEGMENT_HIT_RADIUS_PX, "circle-opacity": 0.01 },
    },
    {
      id: SELECTED_SEGMENT_LAYER_ID,
      type: "circle",
      filter: ["==", ["get", "h3"], selectedH3 ?? ""],
      paint: { "circle-radius": SEGMENT_HIT_RADIUS_PX, "circle-opacity": 0, "circle-stroke-color": colors["--foreground"], "circle-stroke-width": SELECTED_OUTLINE_WIDTH_PX },
    },
  ];

  const handleClick = (feature: MapGeoJSONFeature) => {
    const h3 = feature.properties?.h3;
    if (typeof h3 === "string") onSelect(h3);
  };

  return (
    <>
      <GeoJsonLayer
      id={SEGMENTS_SOURCE_ID}
      data={points}
      layers={layers}
      beforeId={beforeId}
      interactiveLayerIds={SEGMENT_INTERACTIVE_LAYERS}
      onFeatureClick={handleClick}
    />
    </>
  );
}
