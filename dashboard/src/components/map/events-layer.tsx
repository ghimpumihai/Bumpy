import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { useThemeColors } from "@/hooks/use-theme-colors";
import type { RoadEventCollection } from "@/types/sessions";

const COLOR_VARS = ["--event-pothole", "--event-speed-bump", "--event-rail-joint", "--card"] as const;
const EVENT_RADIUS_PX = 4.5;

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
        "circle-radius": ["interpolate", ["linear"], ["zoom"], 12, EVENT_RADIUS_PX * 0.6, 16, EVENT_RADIUS_PX * 1.4],
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
        "circle-stroke-width": 1.2,
        "circle-opacity": ["interpolate", ["linear"], ["get", "confidence"], 0, 0.45, 1, 1],
      },
    },
  ];
  return <GeoJsonLayer id={id} data={data} layers={layers} beforeId={beforeId} />;
}
