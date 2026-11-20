#!/usr/bin/env node
/**
 * Stand-in read API for end-to-end tests: serves the mock backend's handlers (src/mock/handlers.ts)
 * over real HTTP with CORS, so the dashboard can be tested in API mode exactly as it will talk to the
 * real read API (config.json → axios → network → JSON). Dev/test tool only; never deployed.
 *
 *   node scripts/contract-api-server.mjs [--port 8787] [--origin http://localhost:4173]
 */
import http from "node:http";
import { parseArgs } from "node:util";

import { createServer as createViteServer } from "vite";

const { values } = parseArgs({
  options: { port: { type: "string", default: "8787" }, origin: { type: "string", default: "*" } },
});

// Vite resolves the `@/` aliases and the JSON import of the mock modules for us.
const vite = await createViteServer({ server: { middlewareMode: true }, appType: "custom", logLevel: "error" });
const { handleMockRequest, MockHttpError } = await vite.ssrLoadModule("/src/mock/handlers.ts");

let requests = 0;
const server = http.createServer((req, res) => {
  requests += 1;
  const headers = {
    "Access-Control-Allow-Origin": values.origin,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Accept, Content-Type",
    "Content-Type": "application/json",
  };
  const url = new URL(req.url ?? "/", "http://localhost");
  const send = (status, body) => {
    res.writeHead(status, headers);
    res.end(JSON.stringify(body));
  };
  if (req.method === "OPTIONS") return send(204, {});
  if (url.pathname === "/__stats") return send(200, { requests });
  if (req.method !== "GET") return send(405, { error: "the read API is read-only" });
  try {
    send(200, handleMockRequest(url.pathname, url.searchParams));
  } catch (error) {
    if (error instanceof MockHttpError) return send(error.status, { error: error.message });
    console.error(error);
    send(500, { error: "internal error" });
  }
});

server.listen(Number(values.port), () => console.log(`contract read API on http://localhost:${values.port}`));
const stop = () => server.close(() => vite.close().then(() => process.exit(0)));
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
