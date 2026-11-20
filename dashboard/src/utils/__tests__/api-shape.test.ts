import { AxiosHeaders, type AxiosAdapter } from "axios";
import { afterEach, describe, expect, it } from "vitest";

import { api } from "@/config/api-client";
import { ApiContractError, expectShape, shapes } from "@/utils/api-shape";
import { describeError } from "@/utils/describe-error";

const originalAdapter = api.defaults.adapter;
const answer =
  (contentType: string, data: unknown): AxiosAdapter =>
  async (config) => ({ data, status: 200, statusText: "OK", headers: new AxiosHeaders({ "content-type": contentType }), config });

describe("read API boundary", () => {
  afterEach(() => {
    api.defaults.adapter = originalAdapter;
  });

  it("rejects a 200 HTML page (wrong API URL) with a clear error", async () => {
    api.defaults.adapter = answer("text/html; charset=utf-8", "<!doctype html><html></html>");
    const error = await api.get("/api/sessions").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ApiContractError);
    expect(describeError(error)).toMatch(/instead of JSON\. Check the API URL/);
  });

  it("accepts JSON", async () => {
    api.defaults.adapter = answer("application/json", { sessions: [] });
    await expect(api.get("/api/sessions")).resolves.toMatchObject({ data: { sessions: [] } });
  });

  it("checks the envelope the UI dereferences", () => {
    expect(() => expectShape({ sessions: "nope" }, "/api/sessions", shapes.sessionList)).toThrow(ApiContractError);
    expect(() => expectShape(null, "/api/live", shapes.live)).toThrow(ApiContractError);
    expect(expectShape({ serverTime: "2026-11-20T10:00:00Z", devices: [] }, "/api/live", shapes.live)).toEqual({
      serverTime: "2026-11-20T10:00:00Z",
      devices: [],
    });
    expect(() => expectShape({ type: "Feature", geometry: {}, properties: {} }, "/api/sessions/x/track", shapes.track)).toThrow();
  });
});
