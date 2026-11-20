import { AxiosError, AxiosHeaders } from "axios";
import { describe, expect, it } from "vitest";

import { describeError } from "@/utils/describe-error";

const withResponse = (status: number, data: unknown) =>
  new AxiosError("Request failed", "ERR", undefined, null, { status, statusText: "", data, headers: {}, config: { headers: new AxiosHeaders() } });

describe("describeError", () => {
  it("uses the API's own error message", () => {
    expect(describeError(withResponse(404, { error: "session x not found" }))).toBe("Not found: session x not found");
    expect(describeError(withResponse(503, { error: "busy" }))).toBe("HTTP 503: busy");
  });
  it("falls back to the transport message", () => {
    expect(describeError(withResponse(500, "<html>"))).toBe("HTTP 500: Request failed");
    expect(describeError(new AxiosError("Network Error"))).toBe("The read API could not be reached (Network Error).");
    expect(describeError(new Error("boom"))).toBe("boom");
    expect(describeError("plain")).toBe("plain");
  });
});
