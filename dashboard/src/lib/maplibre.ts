import { setWorkerUrl } from "maplibre-gl";
import maplibreWorkerUrl from "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url";

/**
 * MapLibre 6 finds its worker with `new URL(variable, import.meta.url)`, which bundlers cannot follow,
 * so the worker would be missing from the build. Vite bundles it explicitly here and MapLibre is told
 * where it lives. Import this module before creating any map.
 */
setWorkerUrl(maplibreWorkerUrl);

export { Map as MapLibreMap, NavigationControl, ScaleControl } from "maplibre-gl";
