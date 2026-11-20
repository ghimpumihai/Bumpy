import { render } from "@testing-library/react";
import type { Map as MapLibreMap } from "maplibre-gl";
import { describe, expect, it, vi } from "vitest";

import { GeoJsonLayer, type SourceLayer } from "@/components/map/geojson-layer";
import { MapContext } from "@/components/map/map-context";

/** Just enough of MapLibre's API to observe what GeoJsonLayer does to the style. */
function createFakeMap() {
  const sources = new Map<string, { setData: ReturnType<typeof vi.fn> }>();
  const layers: string[] = [];
  const map = {
    style: {},
    getSource: vi.fn((id: string) => sources.get(id)),
    addSource: vi.fn((id: string) => sources.set(id, { setData: vi.fn() })),
    removeSource: vi.fn((id: string) => sources.delete(id)),
    getLayer: vi.fn((id: string) => (layers.includes(id) ? { id } : undefined)),
    addLayer: vi.fn((layer: { id: string }) => layers.push(layer.id)),
    removeLayer: vi.fn((id: string) => layers.splice(layers.indexOf(id), 1)),
    setPaintProperty: vi.fn(),
    setLayoutProperty: vi.fn(),
    setFilter: vi.fn(),
    on: vi.fn(),
    off: vi.fn(),
    getCanvas: () => ({ style: {} }),
  };
  return { map, layers, sources };
}

const DATA = { type: "FeatureCollection" as const, features: [] };
const specs = (selected: string, color: string): SourceLayer[] => [
  { id: "fill", type: "fill", paint: { "fill-color": color } },
  { id: "selected", type: "line", filter: ["==", ["get", "h3"], selected], paint: { "line-width": 3 } },
];

function renderLayer(fake: ReturnType<typeof createFakeMap>, layers: SourceLayer[], data = DATA) {
  return (
    <MapContext.Provider value={{ map: fake.map as unknown as MapLibreMap, styleGeneration: 1 }}>
      <GeoJsonLayer id="segments" data={data} layers={layers} />
    </MapContext.Provider>
  );
}

describe("GeoJsonLayer", () => {
  it("adds the source and its layers once", () => {
    const fake = createFakeMap();
    render(renderLayer(fake, specs("a", "red")));
    expect(fake.map.addSource).toHaveBeenCalledTimes(1);
    expect(fake.layers).toEqual(["fill", "selected"]);
  });

  it("updates filters and paint in place, keeping the layers' draw order", () => {
    const fake = createFakeMap();
    const { rerender } = render(renderLayer(fake, specs("a", "red")));
    fake.map.addLayer.mockClear();
    rerender(renderLayer(fake, specs("b", "blue")));
    expect(fake.map.addLayer).not.toHaveBeenCalled();
    expect(fake.map.removeLayer).not.toHaveBeenCalled();
    expect(fake.map.addSource).toHaveBeenCalledTimes(1);
    expect(fake.map.setFilter).toHaveBeenCalledWith("selected", ["==", ["get", "h3"], "b"]);
    expect(fake.map.setPaintProperty).toHaveBeenCalledWith("fill", "fill-color", "blue");
    expect(fake.map.setPaintProperty).not.toHaveBeenCalledWith("selected", "line-width", expect.anything());
  });

  it("pushes new data without recreating anything, and cleans up layers before the source", () => {
    const fake = createFakeMap();
    const { rerender, unmount } = render(renderLayer(fake, specs("a", "red")));
    const next = { type: "FeatureCollection" as const, features: [] };
    rerender(renderLayer(fake, specs("a", "red"), next));
    expect(fake.sources.get("segments")?.setData).toHaveBeenLastCalledWith(next);
    unmount();
    expect(fake.layers).toEqual([]);
    expect(fake.map.removeSource).toHaveBeenCalledWith("segments");
  });
});
