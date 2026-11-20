import { AxiosError, AxiosHeaders, type AxiosAdapter, type AxiosResponse } from "axios";

import { handleMockRequest, MockHttpError } from "./handlers";

/** A little latency so loading states are exercised the same way as against the real API. */
const MOCK_LATENCY_MS = 150;
const MOCK_ORIGIN = "http://mock.invalid";

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Axios adapter that answers read-API requests from the in-browser mock dataset. */
export const mockAdapter: AxiosAdapter = async (config) => {
  const url = new URL(config.url ?? "/", MOCK_ORIGIN);
  for (const [key, value] of Object.entries((config.params ?? {}) as Record<string, unknown>)) {
    if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
  }
  await delay(MOCK_LATENCY_MS);

  const respond = (status: number, statusText: string, data: unknown): AxiosResponse => ({
    data,
    status,
    statusText,
    headers: new AxiosHeaders({ "content-type": "application/json" }),
    config,
    request: { mock: true },
  });

  if ((config.method ?? "get").toLowerCase() !== "get") {
    const response = respond(405, "Method Not Allowed", { error: "the read API is read-only" });
    throw new AxiosError("Request failed with status code 405", AxiosError.ERR_BAD_REQUEST, config, null, response);
  }
  try {
    // A JSON round trip gives callers the same plain objects a real response would.
    return respond(200, "OK", JSON.parse(JSON.stringify(handleMockRequest(url.pathname, url.searchParams))));
  } catch (error) {
    if (!(error instanceof MockHttpError)) throw error;
    const response = respond(error.status, "Error", { error: error.message });
    throw new AxiosError(
      `Request failed with status code ${error.status}`,
      error.status < 500 ? AxiosError.ERR_BAD_REQUEST : AxiosError.ERR_BAD_RESPONSE,
      config,
      null,
      response,
    );
  }
};
