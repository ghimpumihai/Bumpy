import type { GeoJSON } from "geojson";
import type {
  BackgroundLayerSpecification,
  FilterSpecification,
  GeoJSONSource,
  LayerSpecification,
  Map as MapLibreMap,
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

type StyleProperties = Record<string, unknown>;
type PaintKey = Parameters<MapLibreMap["setPaintProperty"]>[1];
type PaintValue = Parameters<MapLibreMap["setPaintProperty"]>[2];
type LayoutKey = Parameters<MapLibreMap["setLayoutProperty"]>[1];
type LayoutValue = Parameters<MapLibreMap["setLayoutProperty"]>[2];

/** Applies a layer spec to an existing layer without removing it, so its place in the draw order is kept. */
function updateLayerInPlace(map: MapLibreMap, previous: SourceLayer, next: SourceLayer) {
  const previousPaint = (previous.paint ?? {}) as StyleProperties;
  const nextPaint = (next.paint ?? {}) as StyleProperties;
  for (const key of new Set([...Object.keys(previousPaint), ...Object.keys(nextPaint)])) {
    if (JSON.stringify(previousPaint[key]) !== JSON.stringify(nextPaint[key])) map.setPaintProperty(next.id, key as PaintKey, nextPaint[key] as PaintValue);
  }
  const previousLayout = (previous.layout ?? {}) as StyleProperties;
  const nextLayout = (next.layout ?? {}) as StyleProperties;
  for (const key of new Set([...Object.keys(previousLayout), ...Object.keys(nextLayout)])) {
    if (JSON.stringify(previousLayout[key]) !== JSON.stringify(nextLayout[key])) map.setLayoutProperty(next.id, key as LayoutKey, nextLayout[key] as LayoutValue);
  }
  if (JSON.stringify(previous.filter) !== JSON.stringify(next.filter)) {
    map.setFilter(next.id, (next.filter ?? null) as FilterSpecification | null);
  }
}

/**
 * Declarative GeoJSON source + layers on the surrounding `MapCanvas`. The source and layers are created
 * once per map style; later spec changes (selection filter, metric, theme colours) are applied in place,
 * so layers keep their draw order and the data is not uploaded again.
 */
export function GeoJsonLayer({ id, data, layers, beforeId, interactiveLayerIds, onFeatureClick }: GeoJsonLayerProps) {
  const mapState = useMapState();
  const map = mapState?.map ?? null;
  const styleGeneration = mapState?.styleGeneration ?? 0;
  const dataRef = useRef(data);
  const clickRef = useRef(onFeatureClick);
  /** Specs currently on the map, to diff against. */
  const appliedRef = useRef<SourceLayer[]>([]);
  useEffect(() => {
    dataRef.current = data;
    clickRef.current = onFeatureClick;
  });
  const layersKey = JSON.stringify(layers);

  // Source lifetime: once per map style. Cleanup removes the layers before their source.
  useEffect(() => {
    if (!map) return;
    if (!map.getSource(id)) map.addSource(id, { type: "geojson", data: dataRef.current });
    return () => {
      // The map may already be destroyed when the whole canvas unmounts.
      if (!map.style) return;
      for (const layer of appliedRef.current) if (map.getLayer(layer.id)) map.removeLayer(layer.id);
      appliedRef.current = [];
      if (map.getSource(id)) map.removeSource(id);
    };
  }, [map, styleGeneration, id]);

  // Layers: add missing ones, update existing ones in place, remove dropped ones.
  useEffect(() => {
    if (!map || !map.getSource(id)) return;
    const next = JSON.parse(layersKey) as SourceLayer[];
    const previousById = new Map(appliedRef.current.map((layer) => [layer.id, layer]));
    for (const layer of next) {
      const previous = previousById.get(layer.id);
      if (previous && previous.type === layer.type && map.getLayer(layer.id)) {
        updateLayerInPlace(map, previous, layer);
      } else {
        if (map.getLayer(layer.id)) map.removeLayer(layer.id);
        map.addLayer({ ...layer, source: id } as LayerSpecification, beforeId && map.getLayer(beforeId) ? beforeId : undefined);
      }
      previousById.delete(layer.id);
    }
    for (const stale of previousById.values()) if (map.getLayer(stale.id)) map.removeLayer(stale.id);
    appliedRef.current = next;
  }, [map, styleGeneration, id, layersKey, beforeId]);

  useEffect(() => {
    if (!map) return;
    map.getSource<GeoJSONSource>(id)?.setData(data);
  }, [map, styleGeneration, id, data]);

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
