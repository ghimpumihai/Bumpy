import type { IsoDateTime, SessionSource, VehicleType } from "@/types/common";

/** One phone (or replay) currently sending data, from the `live_state` table. */
export interface LiveDevice {
  deviceId: string;
  sessionId: string;
  source: SessionSource;
  vehicleType: VehicleType;
  updatedAt: IsoDateTime;
  lat: number;
  lon: number;
  speedMs: number | null;
  courseDeg: number | null;
  hAccM: number | null;
  /** Roughness of the last few seconds, m/s² (raw, not normalized). */
  roughnessNow: number | null;
  msdvSoFar: number | null;
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
