import type { MapGeoJSONFeature } from "maplibre-gl";

import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { SegmentCollection } from "@/types/segments";
import { stepColorExpression } from "@/utils/scale";

import {
  CONFIRMED_OUTLINE_WIDTH_PX,
  CONFIRMED_POTHOLE_LAYER_ID,
  SEGMENT_FILL_LAYER_ID,
  SEGMENT_FILL_OPACITY,
  SEGMENT_INTERACTIVE_LAYERS,
  SEGMENT_OUTLINE_LAYER_ID,
  SEGMENTS_SOURCE_ID,
  SELECTED_OUTLINE_WIDTH_PX,
  SELECTED_SEGMENT_LAYER_ID,
} from "../utils/constants";
import type { MetricScale } from "../utils/metric";

const COLOR_VARS = ["--scale-1", "--scale-2", "--scale-3", "--scale-4", "--scale-5", "--scale-none", "--event-pothole", "--foreground", "--card"] as const;

interface SegmentsLayerProps {
  data: SegmentCollection;
  scale: MetricScale;
  selectedH3: string | undefined;
  onSelect: (h3: string) => void;
}

export function SegmentsLayer({ data, scale, selectedH3, onSelect }: SegmentsLayerProps) {
  const colors = useThemeColors(COLOR_VARS);
  const bandColors = scale.bands.map((band) => colors[band.colorVar as (typeof COLOR_VARS)[number]]);
  const layers: SourceLayer[] = [
    {
      id: SEGMENT_FILL_LAYER_ID,
      type: "fill",
      paint: {
        "fill-color": stepColorExpression(scale.property, scale.bands, bandColors, colors["--scale-none"]) as never,
        "fill-opacity": SEGMENT_FILL_OPACITY,
      },
    },
    { id: SEGMENT_OUTLINE_LAYER_ID, type: "line", paint: { "line-color": colors["--card"], "line-width": 0.5, "line-opacity": 0.7 } },
    {
      id: CONFIRMED_POTHOLE_LAYER_ID,
      type: "line",
      filter: ["==", ["get", "potholeConfirmed"], true],
      paint: { "line-color": colors["--event-pothole"], "line-width": CONFIRMED_OUTLINE_WIDTH_PX },
    },
    {
      id: SELECTED_SEGMENT_LAYER_ID,
      type: "line",
      filter: ["==", ["get", "h3"], selectedH3 ?? ""],
      paint: { "line-color": colors["--foreground"], "line-width": SELECTED_OUTLINE_WIDTH_PX },
    },
  ];

  const handleClick = (feature: MapGeoJSONFeature) => {
    const h3 = feature.properties?.h3;
    if (typeof h3 === "string") onSelect(h3);
  };

  return (
    <GeoJsonLayer
      id={SEGMENTS_SOURCE_ID}
      data={data}
      layers={layers}
      interactiveLayerIds={SEGMENT_INTERACTIVE_LAYERS}
      onFeatureClick={handleClick}
    />
  );
}
