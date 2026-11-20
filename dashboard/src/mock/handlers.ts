import { cellToBoundary, cellToLatLng, isValidCell } from "h3-js";

import { MS_PER_SECOND, METERS_PER_KM } from "@/constants/units";
import { RoadEventType, SessionSource } from "@/types/common";
import type { LiveDevice, LiveResponse } from "@/types/live";
import type { Overview } from "@/types/overview";
import type { SegmentCollection, SegmentDetail, VehicleFilter } from "@/types/segments";
import { VehicleFilter as VehicleFilters } from "@/types/segments";
import type {
  QualityListResponse,
  RoadEventCollection,
  SessionLabelsResponse,
  SessionListResponse,
  SessionSeries,
  SessionTrack,
} from "@/types/sessions";

import { getDataset, isIncluded, lastSampleIndex, qualityRow, sessionDetail, sessionSummary } from "./dataset";
import { PRIVACY_TRIM_M, SERIES_HZ, type SimulatedSession } from "./simulate";

export class MockHttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type Params = Record<string, string>;
type Handler = (params: Params, query: URLSearchParams) => unknown;

/** Live devices that sent nothing for this long disappear from the live view. */
const LIVE_WINDOW_S = 60;
const LIVE_TRACK_S = 120;
const ROUGHNESS_NOW_WINDOW_S = 3;
const TRACK_HZ = 1;
const LIVE_BATTERY_START = 0.86;
const LIVE_BATTERY_DRAIN_PER_HOUR = 0.12;

const round = (value: number, digits = 6) => Math.round(value * 10 ** digits) / 10 ** digits;

function findSession(id: string): SimulatedSession {
  const sim = getDataset().sims.get(id);
  if (!sim) throw new MockHttpError(404, `session ${id} not found`);
  return sim;
}

function vehicleFilterOf(query: URLSearchParams): VehicleFilter {
  const value = query.get("vehicle") ?? VehicleFilters.ALL;
  if (!(Object.values(VehicleFilters) as string[]).includes(value)) {
    throw new MockHttpError(400, `vehicle must be one of ${Object.values(VehicleFilters).join(", ")}`);
  }
  return value as VehicleFilter;
}

function inPrivacyZone(sim: SimulatedSession, sampleIndex: number): boolean {
  const s = sim.s[sampleIndex];
  return s < PRIVACY_TRIM_M || (!sim.spec.live && s > sim.totalDistanceM - PRIVACY_TRIM_M);
}

function eventsOf(sims: SimulatedSession[], type: string | null): RoadEventCollection {
  const features = sims.flatMap((sim) => {
    const last = lastSampleIndex(sim);
    return sim.events
      .filter((e) => e.sampleIndex <= last && !inPrivacyZone(sim, e.sampleIndex) && (!type || e.type === type))
      .map((e) => ({
        type: "Feature" as const,
        geometry: { type: "Point" as const, coordinates: [round(e.position[0]), round(e.position[1])] },
        properties: {
          id: e.id,
          sessionId: sim.spec.sessionId,
          type: e.type,
          tUtc: new Date(e.tMs).toISOString(),
          speedKmh: round(e.speedMs * 3.6, 1),
          magnitude: round(e.magnitude, 3),
          confidence: round(e.confidence, 2),
          matchedLabel: e.matchedLabel,
          vehicleType: sim.spec.vehicle.type,
        },
      }));
  });
  return { type: "FeatureCollection", features };
}

function overview(): Overview {
  const { sims, aggregation } = getDataset();
  const all = [...sims.values()];
  const summaries = all.map((sim) => sessionSummary(sim));
  const included = all.filter((sim) => isIncluded(sim.spec));
  const allSegments = [...aggregation.segments.values()].map((perFilter) => perFilter.get("all"));
  const lastProcessed = summaries.filter((s) => s.status === "complete").map((s) => Date.parse(s.endedAt ?? s.startedAt));
  return {
    sessions: {
      total: summaries.length,
      upload: summaries.filter((s) => s.source === SessionSource.UPLOAD).length,
      live: summaries.filter((s) => s.source === SessionSource.LIVE).length,
      replay: summaries.filter((s) => s.source === SessionSource.REPLAY).length,
      includedInAgg: included.length,
      mock: summaries.filter((s) => s.isMock).length,
    },
    distanceKm: round(included.reduce((sum, sim) => sum + sim.totalDistanceM, 0) / METERS_PER_KM, 1),
    segments: aggregation.segments.size,
    confirmedPotholes: allSegments.filter((segment) => segment?.potholeConfirmed).length,
    speedBumps: eventsOf(included, RoadEventType.SPEED_BUMP).features.length,
    lastProcessedAt: lastProcessed.length > 0 ? new Date(Math.max(...lastProcessed)).toISOString() : null,
    aggregation: aggregation.info,
  };
}

function segments(query: URLSearchParams): SegmentCollection {
  const filter = vehicleFilterOf(query);
  const { aggregation } = getDataset();
  const features = [...aggregation.segments.entries()].flatMap(([cell, perFilter]) => {
    const properties = perFilter.get(filter);
    if (!properties) return [];
    const ring = cellToBoundary(cell, true).map(([lon, lat]) => [round(lon), round(lat)]);
    return [{ type: "Feature" as const, geometry: { type: "Polygon" as const, coordinates: [ring] }, properties }];
  });
  return { type: "FeatureCollection", features };
}

function segmentDetail(h3: string): SegmentDetail {
  if (!isValidCell(h3)) throw new MockHttpError(400, `${h3} is not an H3 cell`);
  const { aggregation, sims } = getDataset();
  const perFilter = aggregation.segments.get(h3);
  if (!perFilter) throw new MockHttpError(404, `segment ${h3} has no observations`);
  const [lat, lon] = cellToLatLng(h3);
  const observations = [...sims.values()]
    .filter((sim) => !sim.spec.live)
    .flatMap((sim) =>
      sim.observations
        .filter((obs) => obs.cell === h3 && !obs.inPrivacyZone)
        .map((obs) => ({
          sessionId: sim.spec.sessionId,
          vehicleType: sim.spec.vehicle.type,
          tStart: new Date(obs.tStartMs).toISOString(),
          speedKmh: round(obs.meanSpeedMs * 3.6, 1),
          roughnessRms: obs.roughnessRms === null ? null : round(obs.roughnessRms, 4),
          awRms: round(obs.awRms, 4),
          potholeCount: obs.potholeCount,
          includedInAgg: isIncluded(sim.spec),
        })),
    )
    .sort((a, b) => a.tStart.localeCompare(b.tStart));
  return {
    h3,
    center: { lon, lat },
    byVehicle: [...perFilter.values()],
    sicknessBySeat: aggregation.sicknessBySeat.get(h3) ?? [],
    observations,
    updatedAt: aggregation.info.fittedAt,
  };
}

function series(sim: SimulatedSession): SessionSeries {
  const last = lastSampleIndex(sim);
  const slice = (values: Float64Array, digits = 4) => Array.from(values.subarray(0, last + 1), (v) => round(v, digits));
  return {
    t: Array.from(sim.t.subarray(0, last + 1)),
    aVert: slice(sim.aVert),
    aLat: slice(sim.aLat),
    aLon: slice(sim.aLon),
    speed: slice(sim.speed, 3),
    msdv: slice(sim.msdv),
  };
}

function track(sim: SimulatedSession): SessionTrack {
  const last = lastSampleIndex(sim);
  const step = SERIES_HZ / TRACK_HZ;
  const coordinates: [number, number][] = [];
  const times: number[] = [];
  const speeds: number[] = [];
  for (let k = 0; k <= last; k += step) {
    if (inPrivacyZone(sim, k)) continue;
    coordinates.push([round(sim.lon[k]), round(sim.lat[k])]);
    times.push(sim.t[k]);
    speeds.push(round(sim.speed[k], 2));
  }
  return {
    type: "Feature",
    geometry: { type: "LineString", coordinates },
    properties: { sessionId: sim.spec.sessionId, times, speeds, trimmedM: PRIVACY_TRIM_M },
  };
}

function labels(sim: SimulatedSession): SessionLabelsResponse {
  const last = lastSampleIndex(sim);
  return { labels: sim.labels.filter((l) => l.sampleIndex <= last).map(({ tUtc, type, value, note }) => ({ tUtc, type, value, note })) };
}

function live(): LiveResponse {
  const now = Date.now();
  const devices: LiveDevice[] = [...getDataset().sims.values()]
    .filter((sim) => sim.spec.live)
    .flatMap((sim) => {
      const last = lastSampleIndex(sim, now);
      if (now - sim.t[last] > LIVE_WINDOW_S * MS_PER_SECOND) return [];
      const window = ROUGHNESS_NOW_WINDOW_S * SERIES_HZ;
      let sumSquares = 0;
      for (let k = Math.max(0, last - window); k <= last; k++) sumSquares += sim.aVert[k] ** 2;
      const trackPoints: [number, number][] = [];
      for (let k = Math.max(0, last - LIVE_TRACK_S * SERIES_HZ); k <= last; k += SERIES_HZ / TRACK_HZ) {
        if (!inPrivacyZone(sim, k)) trackPoints.push([round(sim.lon[k]), round(sim.lat[k])]);
      }
      const hoursRunning = (sim.t[last] - sim.t[0]) / MS_PER_SECOND / 3600;
      const prev = Math.max(0, last - SERIES_HZ);
      const course = (Math.atan2(sim.lon[last] - sim.lon[prev], sim.lat[last] - sim.lat[prev]) * 180) / Math.PI;
      return [
        {
          deviceId: sim.spec.deviceId,
          sessionId: sim.spec.sessionId,
          source: sim.spec.source,
          vehicleType: sim.spec.vehicle.type,
          updatedAt: new Date(sim.t[last]).toISOString(),
          lat: round(sim.lat[last]),
          lon: round(sim.lon[last]),
          speedMs: round(sim.speed[last], 2),
          courseDeg: round((course + 360) % 360, 1),
          hAccM: 4.2,
          roughnessNow: round(Math.sqrt(sumSquares / (window + 1)), 3),
          msdvSoFar: round(sim.msdv[last], 3),
          battery: round(Math.max(0.05, LIVE_BATTERY_START - hoursRunning * LIVE_BATTERY_DRAIN_PER_HOUR), 2),
          thermal: "nominal",
          track: trackPoints,
        },
      ];
    });
  return { serverTime: new Date(now).toISOString(), devices };
}

function sessionList(query: URLSearchParams): SessionListResponse {
  const source = query.get("source");
  const vehicle = query.get("vehicle");
  const sessions = [...getDataset().sims.values()]
    .map((sim) => sessionSummary(sim))
    .filter((s) => (!source || s.source === source) && (!vehicle || s.vehicle.type === vehicle))
    .sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  return { sessions };
}

function qualityList(): QualityListResponse {
  const sessions = [...getDataset().sims.values()].map((sim) => qualityRow(sim)).sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  return { sessions };
}

function allEvents(query: URLSearchParams): RoadEventCollection {
  const filter = vehicleFilterOf(query);
  const sims = [...getDataset().sims.values()].filter(
    (sim) => isIncluded(sim.spec) && (filter === VehicleFilters.ALL || sim.spec.vehicle.type === filter),
  );
  return eventsOf(sims, query.get("type"));
}

/** Route table: the same paths the read API Lambda serves (dashboard/API.md). */
const ROUTES: [RegExp, Handler][] = [
  [/^\/api\/overview$/, () => overview()],
  [/^\/api\/sessions$/, (_, query) => sessionList(query)],
  [/^\/api\/sessions\/(?<id>[^/]+)$/, ({ id }) => sessionDetail(findSession(id))],
  [/^\/api\/sessions\/(?<id>[^/]+)\/series$/, ({ id }) => series(findSession(id))],
  [/^\/api\/sessions\/(?<id>[^/]+)\/track$/, ({ id }) => track(findSession(id))],
  [/^\/api\/sessions\/(?<id>[^/]+)\/events$/, ({ id }) => eventsOf([findSession(id)], null)],
  [/^\/api\/sessions\/(?<id>[^/]+)\/labels$/, ({ id }) => labels(findSession(id))],
  [/^\/api\/segments$/, (_, query) => segments(query)],
  [/^\/api\/segments\/(?<h3>[^/]+)$/, ({ h3 }) => segmentDetail(h3)],
  [/^\/api\/events$/, (_, query) => allEvents(query)],
  [/^\/api\/live$/, () => live()],
  [/^\/api\/quality$/, () => qualityList()],
];

/** Answers a GET request against the mock dataset; throws `MockHttpError` like the real API answers 4xx. */
export function handleMockRequest(path: string, query: URLSearchParams): unknown {
  for (const [pattern, handler] of ROUTES) {
    const match = pattern.exec(path);
    if (match) return handler(Object.fromEntries(Object.entries(match.groups ?? {}).map(([k, v]) => [k, decodeURIComponent(v)])), query);
  }
  throw new MockHttpError(404, `no route for ${path}`);
}
