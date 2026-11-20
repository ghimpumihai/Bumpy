import { MS_PER_SECOND } from "@/constants/units";
import type { LiveDevice, LiveFreshness } from "@/types/live";
import { formatTime } from "@/utils/format-date-time";
import { formatNumber, formatSeconds } from "@/utils/format-number";
import { StreamStatus } from "@/types/sessions";

import { LIVE_CATCHING_UP_MS, LIVE_STALE_PROBLEM_MS, LIVE_STALE_WARN_MS } from "./constants";


/** `now` must be on the server's clock (see LiveView). */
export function liveFreshness(device: LiveDevice, now: number): LiveFreshness {
  const sampleMs = Date.parse(device.updatedAt);
  const receivedMs = Date.parse(device.receivedAt);
  const silentForMs = Math.max(0, now - receivedMs);
  const transportDelayMs = Math.max(0, receivedMs - sampleMs);
  const ended = device.sessionStatus !== "live";
  const catchingUp = !ended && transportDelayMs > LIVE_CATCHING_UP_MS && silentForMs <= LIVE_STALE_WARN_MS;
  const status = ended
    ? StreamStatus.OK
    : silentForMs > LIVE_STALE_PROBLEM_MS
      ? StreamStatus.PROBLEM
      : silentForMs > LIVE_STALE_WARN_MS || catchingUp
        ? StreamStatus.WARN
        : StreamStatus.OK;
  return { dataAgeMs: Math.max(0, now - sampleMs), silentForMs, transportDelayMs, catchingUp, ended, status };
}

const seconds = (ms: number) => ms / MS_PER_SECOND;

/** The badge text of a live card: never claims "live" for old data, never blames the phone for our outage. */
export function freshnessLabel(device: LiveDevice, freshness: LiveFreshness, apiUnreachable: boolean): string {
  if (apiUnreachable) return `last data ${formatTime(device.updatedAt)}`;
  if (freshness.ended) return "trip ended";
  if (freshness.catchingUp) return `catching up · ${formatNumber(seconds(freshness.transportDelayMs))} s behind`;
  if (freshness.status === StreamStatus.OK) return `${formatSeconds(seconds(freshness.dataAgeMs), 1)} behind the phone`;
  return `no data for ${formatNumber(seconds(freshness.silentForMs))} s`;
}
