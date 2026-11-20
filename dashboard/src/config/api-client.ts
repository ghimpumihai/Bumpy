import axios from "axios";

import { API_TIMEOUT_MS } from "@/constants";
import type { DataSource } from "@/types/config";
import { ApiContractError } from "@/utils/api-shape";

/** The one HTTP client of the app. Its base URL (or the mock adapter) is set once at startup. */
export const api = axios.create({
  timeout: API_TIMEOUT_MS,
  headers: { Accept: "application/json" },
});

// A wrong API URL often answers 200 with an HTML page (e.g. the dashboard itself): reject anything
// that isn't JSON here, so every view shows a clear error instead of crashing on missing fields.
api.interceptors.response.use((response) => {
  const contentType = String(response.headers["content-type"] ?? "");
  if (!contentType.includes("json") || typeof response.data !== "object" || response.data === null) {
    throw new ApiContractError(
      `The read API answered ${response.config.url ?? ""} with ${contentType || "an unknown content type"} instead of JSON. Check the API URL.`,
    );
  }
  return response;
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
