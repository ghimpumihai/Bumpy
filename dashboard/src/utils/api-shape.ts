/** The read API answered, but not with what dashboard/API.md promises (e.g. an HTML page with status 200). */
export class ApiContractError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ApiContractError";
  }
}

type Json = Record<string, unknown>;

export const isRecord = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);
const hasArray = (value: Json, key: string) => Array.isArray(value[key]);
const hasRecord = (value: Json, key: string) => isRecord(value[key]);

/**
 * Checks the envelope of a response before the UI touches it, so a wrong API URL or a proxy page fails
 * with a clear message instead of `Cannot read properties of undefined` deep in a component.
 * Field-level types are the backend's contract (API.md); this guards the shape the UI dereferences.
 */
export function expectShape<T>(data: unknown, route: string, check: (value: Json) => boolean): T {
  if (!isRecord(data) || !check(data)) {
    throw new ApiContractError(`The read API's answer to ${route} doesn't match the contract (dashboard/API.md).`);
  }
  return data as T;
}

export const shapes = {
  overview: (d: Json) => hasRecord(d, "sessions") && hasRecord(d, "aggregation"),
  sessionList: (d: Json) => hasArray(d, "sessions"),
  sessionDetail: (d: Json) =>
    typeof d.sessionId === "string" && hasRecord(d, "vehicle") && hasRecord(d, "quality") && hasRecord(d, "sickness") && hasRecord(d, "eventCounts"),
  series: (d: Json) => ["t", "aVert", "aLat", "aLon", "speed", "msdv"].every((key) => hasArray(d, key)),
  track: (d: Json) => d.type === "Feature" && isRecord(d.geometry) && Array.isArray(d.geometry.coordinates) && hasRecord(d, "properties"),
  featureCollection: (d: Json) => d.type === "FeatureCollection" && hasArray(d, "features"),
  labels: (d: Json) => hasArray(d, "labels"),
  segmentDetail: (d: Json) => typeof d.h3 === "string" && hasArray(d, "byVehicle") && hasArray(d, "observations") && hasArray(d, "sicknessBySeat"),
  live: (d: Json) => typeof d.serverTime === "string" && hasArray(d, "devices"),
  quality: (d: Json) => hasArray(d, "sessions"),
};
