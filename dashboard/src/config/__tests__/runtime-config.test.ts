import axios from "axios";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { applyDataSourceOverride, MissingApiBaseError, resolveDataSource, RuntimeConfigError } from "@/config/runtime-config";

const configResponse = (data: unknown) => vi.spyOn(axios, "get").mockResolvedValue({ data });

describe("resolveDataSource", () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.sessionStorage.clear();
  });
  afterEach(() => vi.restoreAllMocks());

  it("uses the read API from config.json, or mock data when its apiBase is empty", async () => {
    configResponse({ apiBase: "https://api.example.com/" });
    await expect(resolveDataSource("")).resolves.toEqual({ kind: "api", apiBase: "https://api.example.com" });
    configResponse({ apiBase: "" });
    await expect(resolveDataSource("")).resolves.toEqual({ kind: "mock" });
  });

  it("fails visibly when config.json is missing or invalid, instead of showing mock data", async () => {
    vi.spyOn(axios, "get").mockRejectedValue(new axios.AxiosError("Not Found", "ERR", undefined, null, { status: 404 } as never));
    await expect(resolveDataSource("")).rejects.toBeInstanceOf(RuntimeConfigError);
    configResponse({ apiBase: "ftp://api.example.com" });
    await expect(resolveDataSource("")).rejects.toBeInstanceOf(RuntimeConfigError);
    configResponse({ api: "https://api.example.com" });
    await expect(resolveDataSource("")).rejects.toBeInstanceOf(RuntimeConfigError);
  });

  it("ignores stray whitespace around the URL in config.json", async () => {
    configResponse({ apiBase: " https://api.example.com \n" });
    await expect(resolveDataSource("")).resolves.toEqual({ kind: "api", apiBase: "https://api.example.com" });
  });

  it("forces the API with ?mock=0 and explains when there is no URL", async () => {
    configResponse({ apiBase: "" });
    await expect(resolveDataSource("?mock=0")).rejects.toBeInstanceOf(MissingApiBaseError);
  });

  it("remembers ?mock= for the tab, so in-app navigation doesn't switch the data source", async () => {
    configResponse({ apiBase: "https://api.example.com" });
    await expect(resolveDataSource("?mock=1")).resolves.toEqual({ kind: "mock" });
    await expect(resolveDataSource("")).resolves.toEqual({ kind: "mock" });
  });
});

describe("applyDataSourceOverride", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("saves the choice and reloads without ?mock=, which would otherwise win", () => {
    const replace = vi.fn();
    vi.stubGlobal("location", { href: "https://site.example/live?mock=1&x=2", replace });
    window.sessionStorage.setItem("dashboard.forced-mock", "1");
    applyDataSourceOverride({ mode: "api", apiBase: "https://api.example.com" });
    expect(JSON.parse(window.localStorage.getItem("dashboard.data-source") ?? "null")).toEqual({ mode: "api", apiBase: "https://api.example.com" });
    expect(window.sessionStorage.getItem("dashboard.forced-mock")).toBeNull();
    expect(String(replace.mock.calls[0][0])).toBe("https://site.example/live?x=2");
  });
});
