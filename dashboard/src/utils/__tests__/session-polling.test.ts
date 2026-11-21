import { describe, expect, it } from "vitest";

import {
  LIVE_SESSION_POLL_INTERVAL_MS,
  PROCESSING_SESSION_POLL_INTERVAL_MS,
  SILENT_LIVE_SESSION_POLL_INTERVAL_MS,
} from "@/constants";
import type { ProcessingStatus } from "@/types/common";
import { sessionListPollInterval, sessionPollInterval } from "@/utils/session-polling";

const NOW = Date.parse("2026-11-21T12:00:00.000Z");
const MIN = 60_000;
const session = (status: ProcessingStatus, lastDataMinutesAgo: number, ended = status !== "live") => {
  const startedAt = new Date(NOW - (lastDataMinutesAgo + 30) * MIN).toISOString();
  return {
    status,
    startedAt,
    endedAt: ended ? new Date(NOW - lastDataMinutesAgo * MIN).toISOString() : null,
    durationS: 30 * 60,
  };
};

describe("sessionPollInterval", () => {
  it("polls a recording trip every 5 s, and slowly once the phone has gone silent", () => {
    expect(sessionPollInterval(session("live", 0), NOW)).toBe(LIVE_SESSION_POLL_INTERVAL_MS);
    expect(sessionPollInterval(session("live", 19), NOW)).toBe(LIVE_SESSION_POLL_INTERVAL_MS);
    expect(sessionPollInterval(session("live", 25), NOW)).toBe(SILENT_LIVE_SESSION_POLL_INTERVAL_MS);
    // A trip stuck in "live" for days (no Stop, missing batch) never stops being checked, but slowly.
    expect(sessionPollInterval(session("live", 3 * 24 * 60), NOW)).toBe(SILENT_LIVE_SESSION_POLL_INTERVAL_MS);
  });

  it("polls a processing trip for a while after it ended, then gives up", () => {
    expect(sessionPollInterval(session("processing", 1), NOW)).toBe(PROCESSING_SESSION_POLL_INTERVAL_MS);
    expect(sessionPollInterval(session("processing", 119), NOW)).toBe(PROCESSING_SESSION_POLL_INTERVAL_MS);
    expect(sessionPollInterval(session("processing", 121), NOW)).toBe(false);
  });

  it("never polls a finalized trip", () => {
    expect(sessionPollInterval(session("complete", 0), NOW)).toBe(false);
  });

  it("uses start + duration for a trip without an end", () => {
    expect(sessionPollInterval(session("processing", 1, false), NOW)).toBe(PROCESSING_SESSION_POLL_INTERVAL_MS);
  });
});

describe("sessionListPollInterval", () => {
  it("follows the most active session and stops when nothing can change", () => {
    expect(sessionListPollInterval([session("complete", 0), session("processing", 5), session("live", 0)], NOW)).toBe(LIVE_SESSION_POLL_INTERVAL_MS);
    expect(sessionListPollInterval([session("complete", 0), session("processing", 5)], NOW)).toBe(PROCESSING_SESSION_POLL_INTERVAL_MS);
    expect(sessionListPollInterval([session("complete", 0), session("processing", 600)], NOW)).toBe(false);
    expect(sessionListPollInterval([], NOW)).toBe(false);
  });
});
