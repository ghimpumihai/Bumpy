import { describe, expect, it } from "vitest";

import type { LiveDevice } from "@/types/live";
import { freshnessLabel, liveFreshness } from "@/views/live/utils/freshness";

const NOW = Date.parse("2026-11-20T10:00:10.000Z");
const device = (sampleOffsetS: number, receivedOffsetS: number, sessionStatus: LiveDevice["sessionStatus"] = "live") =>
  ({
    updatedAt: new Date(NOW - sampleOffsetS * 1000).toISOString(),
    receivedAt: new Date(NOW - receivedOffsetS * 1000).toISOString(),
    sessionStatus,
  }) as LiveDevice;

describe("liveFreshness", () => {
  it("is ok when data is a few seconds behind the phone", () => {
    expect(liveFreshness(device(4, 1), NOW)).toMatchObject({ status: "ok", catchingUp: false, dataAgeMs: 4000, transportDelayMs: 3000 });
  });
  it("warns, then alarms, when the phone goes silent (dead zone)", () => {
    expect(liveFreshness(device(20, 15), NOW)).toMatchObject({ status: "warn", catchingUp: false, silentForMs: 15000 });
    expect(liveFreshness(device(50, 45), NOW)).toMatchObject({ status: "problem", catchingUp: false });
  });
  it("recognises a backlog arriving after a dead zone as catching up, not live", () => {
    expect(liveFreshness(device(40, 1), NOW)).toMatchObject({ status: "warn", catchingUp: true, transportDelayMs: 39000 });
  });
  it("does not report a trip that ended as a dead zone", () => {
    expect(liveFreshness(device(50, 45, "processing"), NOW)).toMatchObject({ status: "ok", ended: true, catchingUp: false });
  });
});

describe("freshnessLabel", () => {
  const label = (d: LiveDevice, apiUnreachable = false) => freshnessLabel(d, liveFreshness(d, NOW), apiUnreachable);
  it("describes each state without claiming live for old data", () => {
    expect(label(device(4, 1))).toBe("4.0 s behind the phone");
    expect(label(device(20, 15))).toBe("no data for 15 s");
    expect(label(device(40, 1))).toBe("catching up · 39 s behind");
    expect(label(device(50, 45, "complete"))).toBe("trip ended");
  });
  it("never blames the phone when the dashboard lost the read API", () => {
    expect(label(device(50, 45), true)).toMatch(/^last data \d\d:\d\d:\d\d$/);
  });
});
