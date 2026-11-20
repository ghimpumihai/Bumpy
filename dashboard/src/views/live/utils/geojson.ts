import type { FeatureCollection, LineString, Point } from "geojson";

import type { LiveDevice } from "@/types/live";

export function liveTracks(devices: LiveDevice[]): FeatureCollection<LineString, { deviceId: string }> {
  return {
    type: "FeatureCollection",
    features: devices
      .filter((device) => device.track.length > 1)
      .map((device) => ({
        type: "Feature",
        geometry: { type: "LineString", coordinates: device.track },
        properties: { deviceId: device.deviceId },
      })),
  };
}

export function livePositions(devices: LiveDevice[]): FeatureCollection<Point, { deviceId: string; source: string }> {
  return {
    type: "FeatureCollection",
    features: devices.map((device) => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [device.lon, device.lat] },
      properties: { deviceId: device.deviceId, source: device.source },
    })),
  };
}
