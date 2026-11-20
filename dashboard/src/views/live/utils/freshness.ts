import type { LiveDevice, LiveFreshness } from "@/types/live";
import { StreamStatus } from "@/types/sessions";

import { LIVE_CATCHING_UP_MS, LIVE_STALE_PROBLEM_MS, LIVE_STALE_WARN_MS } from "./constants";


/** `now` must be on the server's clock (see LiveView). */
export function liveFreshness(device: LiveDevice, now: number): LiveFreshness {
  const sampleMs = Date.parse(device.updatedAt);
  const receivedMs = Date.parse(device.receivedAt);
  const silentForMs = Math.max(0, now - receivedMs);
  const transportDelayMs = Math.max(0, receivedMs - sampleMs);
  const catchingUp = transportDelayMs > LIVE_CATCHING_UP_MS && silentForMs <= LIVE_STALE_WARN_MS;
  const status =
    silentForMs > LIVE_STALE_PROBLEM_MS ? StreamStatus.PROBLEM : silentForMs > LIVE_STALE_WARN_MS || catchingUp ? StreamStatus.WARN : StreamStatus.OK;
  return { dataAgeMs: Math.max(0, now - sampleMs), silentForMs, transportDelayMs, catchingUp, status };
}
