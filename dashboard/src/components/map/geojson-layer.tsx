import type { GeoJSON } from "geojson";
import type {
  BackgroundLayerSpecification,
  GeoJSONSource,
  LayerSpecification,
  MapGeoJSONFeature,
  MapLayerMouseEvent,
} from "maplibre-gl";
import { useEffect, useRef } from "react";

import { useMapState } from "./map-context";

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;

/** A layer of this source; `source` is filled in by the component. */
export type SourceLayer = DistributiveOmit<Exclude<LayerSpecification, BackgroundLayerSpecification>, "source">;

interface GeoJsonLayerProps {
  /** Source id; layer ids must be unique across the map. */
  id: string;
  data: GeoJSON;
  layers: SourceLayer[];
  /** Id of an existing layer to insert these layers below. */
  beforeId?: string;
  /** Layer ids that react to clicks. Pass a stable (module-level) array. */
  interactiveLayerIds?: string[];
  onFeatureClick?: (feature: MapGeoJSONFeature) => void;
}

/** Declarative GeoJSON source + layers on the surrounding `MapCanvas`. */
export function GeoJsonLayer({ id, data, layers, beforeId, interactiveLayerIds, onFeatureClick }: GeoJsonLayerProps) {
  const mapState = useMapState();
  const map = mapState?.map ?? null;
  const styleGeneration = mapState?.styleGeneration ?? 0;
  const dataRef = useRef(data);
  const clickRef = useRef(onFeatureClick);
  useEffect(() => {
    dataRef.current = data;
    clickRef.current = onFeatureClick;
  });
  const layersKey = JSON.stringify(layers);

  // Source and layers share one lifetime so cleanup always removes the layers before their source.
  // They are re-created only when the layer spec changes (e.g. theme colours), not on data updates.
  useEffect(() => {
    if (!map) return;
    const specs = JSON.parse(layersKey) as SourceLayer[];
    if (!map.getSource(id)) map.addSource(id, { type: "geojson", data: dataRef.current });
    for (const layer of specs) {
      if (!map.getLayer(layer.id)) {
        map.addLayer({ ...layer, source: id } as LayerSpecification, beforeId && map.getLayer(beforeId) ? beforeId : undefined);
      }
    }
    return () => {
      // The map may already be destroyed when the whole canvas unmounts.
      if (!map.style) return;
      for (const layer of specs) if (map.getLayer(layer.id)) map.removeLayer(layer.id);
      if (map.getSource(id)) map.removeSource(id);
    };
  }, [map, styleGeneration, id, layersKey, beforeId]);

  useEffect(() => {
    if (!map) return;
    map.getSource<GeoJSONSource>(id)?.setData(data);
  }, [map, id, data]);

  useEffect(() => {
    if (!map || !interactiveLayerIds?.length) return;
    const onClick = (event: MapLayerMouseEvent) => {
      const feature = event.features?.[0];
      if (feature) clickRef.current?.(feature);
    };
    const onEnter = () => {
      map.getCanvas().style.cursor = "pointer";
    };
    const onLeave = () => {
      map.getCanvas().style.cursor = "";
    };
    for (const layerId of interactiveLayerIds) {
      map.on("click", layerId, onClick);
      map.on("mouseenter", layerId, onEnter);
      map.on("mouseleave", layerId, onLeave);
    }
    return () => {
      for (const layerId of interactiveLayerIds) {
        map.off("click", layerId, onClick);
        map.off("mouseenter", layerId, onEnter);
        map.off("mouseleave", layerId, onLeave);
      }
    };
  }, [map, interactiveLayerIds]);

  return null;
}
