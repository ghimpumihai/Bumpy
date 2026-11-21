import type { Map as MapLibreMap } from "maplibre-gl";

/** Near-black map tones: our lines and dots are the only bright things on it. */
const TONES = {
  background: "#09090c",
  land: "#0c0c10",
  water: "#0a0a0f",
  road: "#33333f",
  label: "#808090",
  border: "#4a4a5c",
  borderMinor: "#363644",
} as const;

const ROAD_FILL = /^(road|bridge|tunnel)_.*_fill/;
const ROAD_CASE = /^(road|bridge|tunnel)_.*_case/;
const HIDDEN = /^(building|building-top|housenumber|poi_|roadname_minor|roadname_sec|watername_lake_pois)/;
const LAND = /^(landcover|park_|landuse)/;

// The layer ids come from the style at runtime, so the typed overloads of `setPaintProperty` don't apply.
type LoosePaint = { setPaintProperty(id: string, property: string, value: unknown): void };
function paint(map: MapLibreMap, id: string, property: string, value: string | number) {
  (map as unknown as LoosePaint).setPaintProperty(id, property, value);
}

/**
 * CARTO Dark Matter is made for browsing; at street zoom its building outlines, house numbers and light road casings
 * compete with whatever we draw. This keeps the roads and the big labels and drops the rest to near-black.
 */
export function quietDarkBasemap(map: MapLibreMap) {
  for (const layer of map.getStyle().layers) {
    const { id, type } = layer;
    if (id === "background") paint(map, id, "background-color", TONES.background);
    else if (HIDDEN.test(id)) map.setLayoutProperty(id, "visibility", "none");
    else if (ROAD_CASE.test(id)) paint(map, id, "line-opacity", 0);
    else if (ROAD_FILL.test(id) || id === "road_path" || id === "bridge_path" || id === "tunnel_path") paint(map, id, "line-color", TONES.road);
    else if (LAND.test(id) && type === "fill") paint(map, id, "fill-color", TONES.land);
    else if (id === "water" && type === "fill") paint(map, id, "fill-color", TONES.water);
    else if (id === "waterway" && type === "line") paint(map, id, "line-color", TONES.water);
    else if (/^boundary_(county|state)/.test(id) && type === "line") paint(map, id, "line-color", TONES.borderMinor);
    else if (/^boundary_country/.test(id) && type === "line") paint(map, id, "line-color", TONES.border);
    else if (id === "water_shadow") map.setLayoutProperty(id, "visibility", "none");
    else if (type === "symbol" && /^(watername|waterway_label)/.test(id)) map.setLayoutProperty(id, "visibility", "none");
    else if (type === "symbol" && /^roadname/.test(id)) paint(map, id, "text-color", TONES.label);
  }
}
