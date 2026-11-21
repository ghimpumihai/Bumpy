import { latLngToCell } from "h3-js";

import { H3_RESOLUTION } from "@/constants/map";
import type { Position } from "@/types/common";
import { bearingDeg, bearingDelta, cumulativeDistances, haversineM, pointAtDistance } from "@/utils/geo";

import { unitHash } from "./random";
import routesJson from "./routes.json";

/**
 * The mock "ground truth": real Cluj-Napoca road geometry (fetched once from OSRM and stored in
 * routes.json) plus road features placed on it. Simulated sessions drive these routes, so different
 * sessions and vehicles pass the same H3 cells, which is what the aggregation needs (plan 02 §8–9).
 */

export const RouteId = {
  CITY_LOOP: "cityLoop",
  BUS_35: "bus35",
  TRAM_101: "tram101",
  FAGET_HILL: "fagetHill",
} as const;
export type RouteId = (typeof RouteId)[keyof typeof RouteId];

/** Spacing of the precomputed route grid. */
export const ROUTE_STEP_M = 5;
/** A vehicle "hits" a point feature when it passes within this distance. */
const FEATURE_HIT_RADIUS_M = 8;
/** Curvature is measured over this distance on each side of a grid point. */
const CURVATURE_HALF_WINDOW_M = 15;

const COBBLESTONE_CENTER: Position = [23.5884, 46.7699];
const COBBLESTONE_RADIUS_M = 170;
/** The winding, undulating road towards Făget starts this far along the hill route. */
const HILL_SECTION_START_M = 1800;

/** Reference roughness (vertical RMS 1–30 Hz, m/s²) a car feels at 36 km/h on each surface. */
const ROUGHNESS_SMOOTH = 0.42;
const ROUGHNESS_COBBLESTONES = 1.55;
const ROUGH_PATCH_FACTOR = 1.9;
const ROUGH_PATCH_SHARE = 0.12;
const TRAM_TRACK_ROUGHNESS = 0.68;

/** Frequency-weighted (Wf) vertical RMS, m/s²: low in town, high on the undulating hill road. */
const AW_CITY = 0.055;
const AW_HILL = 0.24;

export const RoadFeatureType = {
  POTHOLE: "pothole",
  SPEED_BUMP: "speed_bump",
} as const;
export type RoadFeatureType = (typeof RoadFeatureType)[keyof typeof RoadFeatureType];

interface RoadFeature {
  id: string;
  type: RoadFeatureType;
  position: Position;
}

export interface RouteSample {
  s: number;
  position: Position;
  cell: string;
  /** Signed curvature, 1/m (positive = left turn). */
  curvature: number;
  headingDeg: number;
  /** Road features within the hit radius of this grid point. */
  features: RoadFeature[];
  cobblestones: boolean;
  hillSection: boolean;
}

export interface Route {
  id: RouteId;
  name: string;
  line: Position[];
  lengthM: number;
  samples: RouteSample[];
}

export interface CellTruth {
  /** Reference roughness for a car at 36 km/h, m/s². */
  roughness: number;
  /** Weighted RMS for a car, vertical (Wf) and lateral (Wy) combined, m/s² (D41). */
  awRms: number;
  /** The lateral part of awRms: sway in curves. */
  awLatRms: number;
}

const ROUTE_NAMES: Record<RouteId, string> = {
  cityLoop: "City-centre loop",
  bus35: "Bus line 35",
  tram101: "Tram line 101",
  fagetHill: "Calea Turzii – Făget hill road",
};

/** Features are placed by distance along a route so they always sit on the road. */
const FEATURE_PLACEMENT: { route: RouteId; distanceM: number; type: RoadFeatureType }[] = [
  { route: "cityLoop", distanceM: 700, type: "pothole" },
  { route: "cityLoop", distanceM: 2300, type: "pothole" },
  { route: "cityLoop", distanceM: 3900, type: "pothole" },
  { route: "cityLoop", distanceM: 5400, type: "pothole" },
  { route: "cityLoop", distanceM: 1500, type: "speed_bump" },
  { route: "cityLoop", distanceM: 4600, type: "speed_bump" },
  { route: "bus35", distanceM: 4200, type: "pothole" },
  { route: "bus35", distanceM: 2600, type: "speed_bump" },
  { route: "tram101", distanceM: 900, type: "pothole" },
  { route: "fagetHill", distanceM: 3000, type: "pothole" },
  { route: "fagetHill", distanceM: 5600, type: "pothole" },
];

/** Bus stops and traffic lights, as distances along each route. */
export const STOPS: Record<RouteId, number[]> = {
  cityLoop: [1000, 2700, 4300],
  bus35: [450, 900, 1400, 1900, 2450, 3000, 3500, 4100, 4700, 5300],
  tram101: [600, 1300, 2000, 2700, 3400, 4100],
  fagetHill: [900],
};

function buildFeatures(lines: Record<RouteId, Position[]>): RoadFeature[] {
  return FEATURE_PLACEMENT.map((placement, index) => {
    const line = lines[placement.route];
    return {
      id: `${placement.type}-${index}`,
      type: placement.type,
      position: pointAtDistance(line, cumulativeDistances(line), placement.distanceM),
    };
  });
}

function buildRoute(id: RouteId, line: Position[], features: RoadFeature[]): Route {
  const cumulative = cumulativeDistances(line);
  const lengthM = cumulative[cumulative.length - 1];
  const positions: Position[] = [];
  for (let s = 0; s <= lengthM; s += ROUTE_STEP_M) positions.push(pointAtDistance(line, cumulative, s));

  const window = Math.round(CURVATURE_HALF_WINDOW_M / ROUTE_STEP_M);
  const samples = positions.map((position, i): RouteSample => {
    const prev = positions[Math.max(0, i - window)];
    const next = positions[Math.min(positions.length - 1, i + window)];
    const here = positions[Math.min(positions.length - 1, i + 1)];
    const headingIn = bearingDeg(prev, position);
    const headingOut = bearingDeg(position, next);
    const span = haversineM(prev, position) + haversineM(position, next);
    // Bearings grow clockwise, so a left turn has a negative delta.
    const curvature = span > 1 ? (-bearingDelta(headingIn, headingOut) * Math.PI) / 180 / span : 0;
    const s = i * ROUTE_STEP_M;
    return {
      s,
      position,
      cell: latLngToCell(position[1], position[0], H3_RESOLUTION),
      curvature,
      headingDeg: bearingDeg(position, here === position ? next : here),
      features: features.filter((feature) => haversineM(feature.position, position) <= FEATURE_HIT_RADIUS_M),
      cobblestones: haversineM(position, COBBLESTONE_CENTER) <= COBBLESTONE_RADIUS_M,
      hillSection: id === "fagetHill" && s >= HILL_SECTION_START_M,
    };
  });
  return { id, name: ROUTE_NAMES[id], line, lengthM, samples };
}

function cellTruth(sample: RouteSample, routeId: RouteId): CellTruth {
  const noise = Math.exp((unitHash(`${sample.cell}:rough`) - 0.5) * 0.4);
  let roughness = ROUGHNESS_SMOOTH * noise;
  if (sample.cobblestones) roughness = ROUGHNESS_COBBLESTONES * noise;
  else if (unitHash(`${sample.cell}:patch`) < ROUGH_PATCH_SHARE) roughness *= ROUGH_PATCH_FACTOR;
  else if (routeId === "tram101") roughness = Math.max(roughness, TRAM_TRACK_ROUGHNESS * noise);

  const awNoise = 0.8 + 0.4 * unitHash(`${sample.cell}:aw`);
  const awLatRms = sample.hillSection ? Math.min(0.12, Math.abs(sample.curvature) * 4) * awNoise : 0;
  const awRms = sample.hillSection ? AW_HILL * awNoise + awLatRms : AW_CITY * awNoise;
  return { roughness, awRms, awLatRms };
}

export interface World {
  routes: Record<RouteId, Route>;
  features: RoadFeature[];
  cells: Map<string, CellTruth>;
}

function buildWorld(): World {
  const lines = routesJson as Record<RouteId, Position[]>;
  const features = buildFeatures(lines);
  const routes = Object.fromEntries(
    (Object.keys(lines) as RouteId[]).map((id) => [id, buildRoute(id, lines[id], features)]),
  ) as Record<RouteId, Route>;

  // A cell's truth must not depend on which route reaches it, so the first route to claim it wins
  // (iteration order is fixed, so this stays deterministic).
  const cells = new Map<string, CellTruth>();
  for (const route of Object.values(routes)) {
    for (const sample of route.samples) {
      if (!cells.has(sample.cell)) cells.set(sample.cell, cellTruth(sample, route.id));
    }
  }
  return { routes, features, cells };
}

let cachedWorld: World | null = null;

export function getWorld(): World {
  cachedWorld ??= buildWorld();
  return cachedWorld;
}
