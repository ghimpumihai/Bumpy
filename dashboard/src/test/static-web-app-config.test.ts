import { describe, expect, it } from "vitest";

import rawConfig from "../../public/staticwebapp.config.json";

interface StaticWebAppConfig {
  navigationFallback: { rewrite: string; exclude: string[] };
  routes: { route: string; headers?: Record<string, string> }[];
  globalHeaders: Record<string, string>;
}

const config: StaticWebAppConfig = rawConfig;
const csp = Object.fromEntries(
  config.globalHeaders["Content-Security-Policy"].split(";").map((directive) => {
    const [name, ...values] = directive.trim().split(/\s+/);
    return [name, values];
  }),
);

describe("staticwebapp.config.json (Azure Static Web Apps)", () => {
  it("serves index.html for client-side routes so deep links and refreshes work", () => {
    expect(config.navigationFallback.rewrite).toBe("/index.html");
  });

  it("never rewrites or caches config.json, which the deploy workflow writes", () => {
    expect(config.navigationFallback.exclude).toContain("/config.json");
    expect(config.routes.find((route) => route.route === "/config.json")?.headers?.["Cache-Control"]).toBe("no-store");
  });

  it("caches hashed assets for good but always revalidates index.html", () => {
    expect(config.routes.find((route) => route.route === "/assets/*")?.headers?.["Cache-Control"]).toContain("immutable");
    expect(config.routes.find((route) => route.route === "/index.html")?.headers?.["Cache-Control"]).toBe("no-cache");
  });

  it("sends a CSP that allows only what the app needs", () => {
    expect(csp["script-src"]).toEqual(["'self'"]);
    // The read API and the OpenFreeMap tiles are fetched over HTTPS.
    expect(csp["connect-src"]).toEqual(["'self'", "https:"]);
    // MapLibre's worker is a same-origin file.
    expect(csp["worker-src"]).toContain("'self'");
    expect(csp["frame-ancestors"]).toEqual(["'none'"]);
    expect(csp["object-src"]).toEqual(["'none'"]);
  });
});
