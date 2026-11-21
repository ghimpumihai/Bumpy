/**
 * H3 resolution of road segments. Resolution 11 has an average edge of 24.9 m, the "about 25 m"
 * hexagons of plan 02 §8. The backend owns this; the dashboard only needs it for mock data.
 */
export const H3_RESOLUTION = 11;

/** OpenFreeMap vector tiles, no key needed (plan 02 §5, research notes "Dashboard"). */
export const MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/positron";
/** Dark base map for the heat map: bright trip lines on dark, like Strava's heatmap. CARTO Dark Matter, free with attribution. */
export const MAP_STYLE_DARK_URL = "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json";

/** Cluj-Napoca city centre. */
export const DEFAULT_MAP_CENTER: [number, number] = [23.5935, 46.7675];
export const DEFAULT_MAP_ZOOM = 13.2;
export const FIT_BOUNDS_PADDING_PX = 48;
export const FIT_BOUNDS_MAX_ZOOM = 16;
export const FIT_BOUNDS_DURATION_MS = 600;

/** Event dots grow from city zoom to street zoom; low-confidence detections are drawn fainter. */
export const EVENT_DOT = {
  radiusPx: 3.8,
  minZoom: 12,
  maxZoom: 16,
  minZoomScale: 0.6,
  maxZoomScale: 1.4,
  strokePx: 1.4,
  minOpacity: 0.45,
} as const;
/** Switch to the plain fallback style if the base-map style hasn't loaded by then. */
export const BASEMAP_STYLE_TIMEOUT_MS = 8000;
