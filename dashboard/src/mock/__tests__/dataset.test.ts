import { describe, expect, it } from "vitest";

import { getDataset, sessionDetail, sessionSummary } from "@/mock/dataset";
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
    const { info } = getDataset().aggregation;
    expect(info.method).toBe("model");
    expect(info.beta).toBeCloseTo(TRUE_SPEED_EXPONENT, 1);
    expect(info.vehicleEffects.car).toBe(0);
    expect(info.vehicleEffects.bus).toBeCloseTo(Math.log(1.35), 1);
    expect(info.vehicleEffects.tram).toBeCloseTo(Math.log(1.18), 1);
  });

  it("never aggregates replays, live-only or bad sessions", () => {
    const { sessions } = get<SessionListResponse>("/api/sessions");
    for (const s of sessions) {
      if (s.source !== "upload" || s.qualityStatus === "bad") expect(s.includeInAgg).toBe(false);
    }
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

  it("answers unknown sessions and bad filters with HTTP errors", () => {
    expect(() => get("/api/sessions/nope")).toThrowError(MockHttpError);
    expect(() => get("/api/segments", "vehicle=plane")).toThrow(/vehicle must be/);
    expect(() => get("/api/nothing")).toThrow(/no route/);
  });
});
