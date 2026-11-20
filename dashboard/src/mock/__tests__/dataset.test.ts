import { describe, expect, it } from "vitest";

import {
  getAggregation,
  getDataset,
  isIncluded,
  lastSampleIndex,
  processingStatus,
  receivedAtMs,
  sessionDetail,
  sessionSummary,
} from "@/mock/dataset";
import { handleMockRequest, MockHttpError } from "@/mock/handlers";
import { PRIVACY_TRIM_M, TRUE_SPEED_EXPONENT } from "@/mock/simulate";
import { getWorld } from "@/mock/world";
import type { Overview } from "@/types/overview";
import type { SegmentCollection } from "@/types/segments";
import type { SessionListResponse, SessionTrack } from "@/types/sessions";
import { cumulativeDistances, haversineM } from "@/utils/geo";

const get = <T,>(path: string, query = "") => handleMockRequest(path, new URLSearchParams(query)) as T;

describe("mock dataset", () => {
  it("is deterministic for recorded sessions", () => {
    const a = getDataset().sims.get("3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11");
    expect(a).toBeDefined();
    expect(a?.t.length).toBeGreaterThan(1000);
    expect(a?.totalDistanceM).toBeGreaterThan(10_000);
  });

  it("recovers the true speed exponent and vehicle effects with the fixed-effects fit", () => {
    const { info } = getAggregation();
    expect(info.method).toBe("model");
    expect(info.beta).toBeCloseTo(TRUE_SPEED_EXPONENT, 1);
    expect(info.vehicleEffects.car).toBe(0);
    expect(info.vehicleEffects.bus).toBeCloseTo(Math.log(1.35), 1);
    expect(info.vehicleEffects.tram).toBeCloseTo(Math.log(1.18), 1);
  });

  it("aggregates only finalized trips with known context; never replays or bad sessions", () => {
    const { sessions } = get<SessionListResponse>("/api/sessions");
    for (const s of sessions) {
      const expected =
        s.status === "complete" && s.source !== "replay" && s.qualityStatus !== "bad" && !s.exclusionReasons.includes("unknown_context");
      expect(s.includeInAgg, s.sessionId).toBe(expected);
      if (s.source === "live" && s.status !== "complete") expect(s.exclusionReasons).toContain("live_only");
    }
    // Streamed trips are the main dataset (plan 02 D32); uploads are only the fallback.
    const included = sessions.filter((s) => s.includeInAgg);
    expect(included.filter((s) => s.source === "live").length).toBeGreaterThan(included.filter((s) => s.source === "upload").length);
    expect(sessions.find((s) => s.source === "replay")?.exclusionReasons).toContain("replay");
    expect(sessions.every((s) => s.isMock)).toBe(true);
  });

  it("confirms potholes where several passes detected one", () => {
    const overview = get<Overview>("/api/overview");
    expect(overview.confirmedPotholes).toBeGreaterThanOrEqual(3);
    const segments = get<SegmentCollection>("/api/segments", "vehicle=all");
    const confirmed = segments.features.filter((f) => f.properties.potholeConfirmed);
    const world = getWorld();
    for (const feature of confirmed) {
      const [lon, lat] = feature.geometry.coordinates[0][0];
      const nearest = Math.min(...world.features.filter((f) => f.type === "pothole").map((f) => haversineM(f.position, [lon, lat])));
      // A false positive can only be confirmed if it repeats, so confirmed cells sit on real potholes.
      expect(nearest).toBeLessThan(60);
    }
  });

  it("rates cobblestones rougher than smooth asphalt after normalization", () => {
    const segments = get<SegmentCollection>("/api/segments", "vehicle=all").features.map((f) => f.properties);
    const values = segments.flatMap((s) => (s.roughness === null ? [] : [s.roughness])).sort((a, b) => a - b);
    expect(values[values.length - 1]).toBeGreaterThan(1.2);
    expect(values[Math.floor(values.length / 2)]).toBeLessThan(0.8);
  });

  it("trims the end of a finished trip too (open route, so start and end differ)", () => {
    const id = "e4c7b2a9-6d1f-4e38-8b0a-3c9e5d2f1b77";
    const sim = getDataset().sims.get(id);
    if (!sim) throw new Error("bus session missing");
    const track = get<SessionTrack>(`/api/sessions/${id}/track`);
    const lastSample: [number, number] = [sim.lon[sim.lon.length - 1], sim.lat[sim.lat.length - 1]];
    expect(haversineM(lastSample, track.geometry.coordinates.at(-1) as [number, number])).toBeGreaterThan(PRIVACY_TRIM_M * 0.6);
  });

  it("counts only the events the API publishes", () => {
    for (const s of get<SessionListResponse>("/api/sessions").sessions) {
      const events = get<{ features: { properties: { type: string } }[] }>(`/api/sessions/${s.sessionId}/events`).features;
      expect(events.filter((e) => e.properties.type === "pothole")).toHaveLength(s.eventCounts.pothole);
    }
  });

  it("never teleports: consecutive positions are at most a few metres apart", () => {
    for (const sim of getDataset().sims.values()) {
      let maxStep = 0;
      for (let k = 1; k < sim.t.length; k++) maxStep = Math.max(maxStep, haversineM([sim.lon[k - 1], sim.lat[k - 1]], [sim.lon[k], sim.lat[k]]));
      // 0.2 s at the fastest cruise speed (50 km/h ≈ 2.8 m), plus a grid-step margin.
      expect(maxStep, sim.spec.sessionId).toBeLessThan(8);
    }
  });

  it("ends live trips when their recording ends, then finalizes them", () => {
    const sim = getDataset().sims.get("c3e9a7b1-6d2f-4f80-b4e5-9a1c7e3d5b87");
    if (!sim) throw new Error("live replay missing");
    const end = sim.t[sim.t.length - 1];
    expect(sessionSummary(sim, end + 120_000)).toMatchObject({ status: "processing" });
    expect(sessionSummary(sim, end + 120_000).endedAt).not.toBeNull();
    expect(sessionSummary(sim, end + 10 * 60_000)).toMatchObject({ status: "complete", includeInAgg: false });
    expect(sessionSummary(sim, end + 10 * 60_000).exclusionReasons).toEqual(["replay"]);
  });

  it("trims the public track at both ends for privacy", () => {
    const sim = getDataset().sims.get("3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11");
    const track = get<SessionTrack>("/api/sessions/3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11/track");
    const start: [number, number] = [sim?.lon[0] ?? 0, sim?.lat[0] ?? 0];
    expect(haversineM(start, track.geometry.coordinates[0] as [number, number])).toBeGreaterThan(PRIVACY_TRIM_M * 0.6);
    expect(track.properties.times).toHaveLength(track.geometry.coordinates.length);
    expect(cumulativeDistances(track.geometry.coordinates as [number, number][]).at(-1)).toBeGreaterThan(5000);
  });

  it("grows live sessions with the clock", () => {
    const sim = getDataset().sims.get("aa61f0d4-3b8e-4c5a-9d27-6f1e4b8c0d76");
    if (!sim) throw new Error("live session missing");
    const now = Date.now();
    const early = sessionSummary(sim, now);
    const later = sessionSummary(sim, now + 60_000);
    expect(early.status).toBe("live");
    expect(early.endedAt).toBeNull();
    expect(later.distanceM).toBeGreaterThan(early.distanceM);
    expect(sessionDetail(sim, now).detection).not.toBeNull();
  });

  it("finalizes a trip a few minutes after it ends, and only then adds it to the map", () => {
    const sim = getDataset().sims.get("5e8c1a7d-2b9f-4c63-a0d4-8f1e3b6c9a21");
    if (!sim) throw new Error("recently ended session missing");
    const now = Date.now();
    expect(processingStatus(sim, now)).toBe("processing");
    expect(sessionSummary(sim, now).exclusionReasons).toEqual(["live_only"]);
    expect(isIncluded(sim, now)).toBe(false);
    const later = now + 10 * 60_000;
    expect(processingStatus(sim, later)).toBe("complete");
    expect(isIncluded(sim, later)).toBe(true);
    // The aggregation step re-runs: one more trip, more passes on the shared loop.
    const passes = (at: number) => [...getAggregation(at).segments.values()].reduce((sum, f) => sum + (f.get("all")?.nPasses ?? 0), 0);
    expect(passes(later)).toBeGreaterThan(passes(now));
  });

  it("keeps trips with unknown context off the map but finalizes incomplete ones", () => {
    const sessions = get<SessionListResponse>("/api/sessions").sessions;
    const unknown = sessions.find((s) => s.sessionId === "91d4b7e2-6a3c-4f58-9b0e-2c7a5d8f1e43");
    expect(unknown?.includeInAgg).toBe(false);
    expect(unknown?.exclusionReasons).toEqual(["unknown_context"]);
    expect(unknown?.vehicle.type).toBe("unknown");
    const crashed = sessions.find((s) => s.sessionId === "0e6b9a4f-3c27-4d85-b1e9-8c5a2d4f7b44");
    expect(crashed?.incomplete).toBe(true);
    expect(crashed?.includeInAgg).toBe(true);
  });

  it("lets a live device go stale in a dead zone, then catch up faster than real time", () => {
    const sim = getDataset().sims.get("aa61f0d4-3b8e-4c5a-9d27-6f1e4b8c0d76");
    const zone = sim?.spec.deadZone;
    if (!sim || !zone) throw new Error("live car with a dead zone missing");
    const at = (seconds: number) => sim.startMs + seconds * 1000;
    const before = lastSampleIndex(sim, at(zone.startS - 5));
    const inZone = [at(zone.startS + 5), at(zone.startS + zone.durationS - 1)].map((t) => lastSampleIndex(sim, t));
    expect(inZone[0]).toBe(inZone[1]); // nothing new arrives in the dead zone
    expect(receivedAtMs(sim, at(zone.startS + 30))).toBeLessThan(at(zone.startS));
    const catchingUp = at(zone.startS + zone.durationS + 4);
    expect(receivedAtMs(sim, catchingUp) - sim.t[lastSampleIndex(sim, catchingUp)]).toBeGreaterThan(10_000);
    expect(lastSampleIndex(sim, at(zone.startS + zone.durationS + 60))).toBeGreaterThan(before);
    const caughtUp = at(zone.startS + zone.durationS + 60);
    expect(receivedAtMs(sim, caughtUp) - sim.t[lastSampleIndex(sim, caughtUp)]).toBeLessThan(5_000);
  });

  it("answers unknown sessions and bad filters with HTTP errors", () => {
    expect(() => get("/api/sessions/nope")).toThrowError(MockHttpError);
    expect(() => get("/api/segments", "vehicle=plane")).toThrow(/vehicle must be/);
    expect(() => get("/api/nothing")).toThrow(/no route/);
    expect(() => get("/api/sessions", "source=bogus")).toThrow(/source must be/);
    expect(() => get("/api/sessions", "vehicle=plane")).toThrow(/vehicle must be/);
    expect(() => get("/api/events", "type=meteor")).toThrow(/type must be/);
  });
});
