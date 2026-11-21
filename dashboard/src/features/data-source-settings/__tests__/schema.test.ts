import { describe, expect, it } from "vitest";

import { dataSourceFormSchema, isBlockedMixedContent } from "@/features/data-source-settings/schema";

describe("dataSourceFormSchema", () => {
  it("accepts mock mode whatever is left in the hidden URL field", () => {
    expect(dataSourceFormSchema.parse({ mode: "mock", apiBase: "" })).toEqual({ mode: "mock", apiBase: "" });
    expect(dataSourceFormSchema.parse({ mode: "mock", apiBase: "http://half-typ" })).toEqual({ mode: "mock", apiBase: "" });
    expect(dataSourceFormSchema.parse({ mode: "mock", apiBase: "not a url" })).toEqual({ mode: "mock", apiBase: "" });
  });

  it("requires a URL in API mode and keeps it optional in automatic mode", () => {
    expect(dataSourceFormSchema.safeParse({ mode: "api", apiBase: "" }).success).toBe(false);
    expect(dataSourceFormSchema.parse({ mode: "auto", apiBase: "" })).toEqual({ mode: "auto", apiBase: "" });
    expect(dataSourceFormSchema.parse({ mode: "api", apiBase: " https://read-api.example.com " }).apiBase).toBe("https://read-api.example.com");
  });

  it("only accepts http(s) URLs", () => {
    expect(dataSourceFormSchema.safeParse({ mode: "api", apiBase: "javascript:alert(1)" }).success).toBe(false);
    expect(dataSourceFormSchema.safeParse({ mode: "auto", apiBase: "ftp://example.com" }).success).toBe(false);
  });
});

describe("isBlockedMixedContent", () => {
  it("rejects a plain-http API only when the site itself is served over HTTPS", () => {
    expect(isBlockedMixedContent("http://localhost:8000", "https:")).toBe(true);
    expect(isBlockedMixedContent("HTTP://read-api.example.com", "https:")).toBe(true);
    expect(isBlockedMixedContent("https://read-api.example.com", "https:")).toBe(false);
    expect(isBlockedMixedContent("http://localhost:8000", "http:")).toBe(false);
    expect(isBlockedMixedContent("http://localhost:8000", undefined)).toBe(false);
  });
});
