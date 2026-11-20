import type { IsoDateTime, SessionSource, VehicleType } from "@/types/common";
import type { StreamStatus } from "@/types/sessions";

/** The passenger's most recent motion-sickness rating (MISC 0–10). */
export interface LatestRating {
  value: number;
  tUtc: IsoDateTime;
}

/** One phone (or replay) currently sending data, from the `live_state` table. */
export interface LiveDevice {
  deviceId: string;
  sessionId: string;
  source: SessionSource;
  vehicleType: VehicleType;
  /** Time of the newest sample processed for this device (phone clock, UTC). */
  updatedAt: IsoDateTime;
  /** When the ingest function received the batch holding that sample. `receivedAt − updatedAt` is the
   *  transport delay; a large one means the phone is sending a backlog after a dead zone ("catching up"). */
  receivedAt: IsoDateTime;
  lat: number;
  lon: number;
  speedMs: number | null;
  courseDeg: number | null;
  hAccM: number | null;
  /** Roughness of the last few seconds, m/s² (raw, not normalized). */
  roughnessNow: number | null;
  msdvSoFar: number | null;
  latestRating: LatestRating | null;
  battery: number | null;
  thermal: string | null;
  /** Recent positions `[lon, lat]`, oldest first. */
  track: [number, number][];
}

/** `GET /api/live`. */
export interface LiveResponse {
  serverTime: IsoDateTime;
  devices: LiveDevice[];
}

/** How current a live device's data is, derived from `updatedAt`, `receivedAt` and the server clock. */
export interface LiveFreshness {
  /** now − sample time: how old the newest data on screen is (everything included). */
  dataAgeMs: number;
  /** now − arrival time: how long since the phone last got a batch through. */
  silentForMs: number;
  /** arrival − sample time: the batch spent this long on the phone (queued in a dead zone) and in transit. */
  transportDelayMs: number;
  /** The phone is sending a backlog after a dead zone (plan 02 §5, "Gaps and late data"). */
  catchingUp: boolean;
  status: StreamStatus;
}
