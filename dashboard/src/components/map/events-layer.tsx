import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { EVENT_DOT } from "@/constants/map";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { RoadEventCollection } from "@/types/sessions";

const COLOR_VARS = ["--event-pothole", "--event-speed-bump", "--event-rail-joint", "--card"] as const;

interface EventsLayerProps {
  id: string;
  data: RoadEventCollection;
  /** Insert below this layer. */
  beforeId?: string;
}

/** Detected potholes, speed bumps and rail joints as coloured dots (shared by the map and session views). */
export function EventsLayer({ id, data, beforeId }: EventsLayerProps) {
  const colors = useThemeColors(COLOR_VARS);
  const layers: SourceLayer[] = [
    {
      id: `${id}-circle`,
      type: "circle",
      paint: {
        "circle-radius": [
          "interpolate",
          ["linear"],
          ["zoom"],
          EVENT_DOT.minZoom,
          EVENT_DOT.radiusPx * EVENT_DOT.minZoomScale,
          EVENT_DOT.maxZoom,
          EVENT_DOT.radiusPx * EVENT_DOT.maxZoomScale,
        ],
        "circle-color": [
          "match",
          ["get", "type"],
          "pothole",
          colors["--event-pothole"],
          "speed_bump",
          colors["--event-speed-bump"],
          colors["--event-rail-joint"],
        ],
        "circle-stroke-color": colors["--card"],
        "circle-stroke-width": EVENT_DOT.strokePx,
        "circle-opacity": ["interpolate", ["linear"], ["get", "confidence"], 0, EVENT_DOT.minOpacity, 1, 1],
      },
    },
  ];
  return <GeoJsonLayer id={id} data={data} layers={layers} beforeId={beforeId} />;
}
