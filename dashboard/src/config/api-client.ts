import axios from "axios";

import { API_TIMEOUT_MS } from "@/constants";
import type { DataSource } from "@/types/config";

/** The one HTTP client of the app. Its base URL (or the mock adapter) is set once at startup. */
export const api = axios.create({
  timeout: API_TIMEOUT_MS,
  headers: { Accept: "application/json" },
});

/** Points the client at the read API, or swaps in the mock backend (loaded lazily, never shipped to API users). */
export async function configureApiClient(source: DataSource): Promise<void> {
  if (source.kind === "api") {
    api.defaults.baseURL = source.apiBase;
    return;
  }
  const { mockAdapter } = await import("@/mock/mock-adapter");
  api.defaults.baseURL = "";
  api.defaults.adapter = mockAdapter;
}
