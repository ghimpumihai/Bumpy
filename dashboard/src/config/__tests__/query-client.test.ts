import { AxiosError, AxiosHeaders } from "axios";
import { describe, expect, it } from "vitest";

import { shouldRetry } from "@/config/query-client";

const httpError = (status: number) =>
  new AxiosError("failed", "ERR", undefined, null, {
    status,
    statusText: "",
    data: {},
    headers: {},
    config: { headers: new AxiosHeaders() },
  });

describe("shouldRetry", () => {
  it("does not retry client errors", () => {
    expect(shouldRetry(0, httpError(404))).toBe(false);
    expect(shouldRetry(0, httpError(400))).toBe(false);
  });
  it("retries server and network errors a limited number of times", () => {
    expect(shouldRetry(0, httpError(503))).toBe(true);
    expect(shouldRetry(0, new AxiosError("Network Error"))).toBe(true);
    expect(shouldRetry(2, httpError(503))).toBe(false);
  });
});
