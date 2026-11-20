import { defineConfig, devices } from "@playwright/test";

const MOCK_PORT = 4173;
const API_SITE_PORT = 4176;
const API_PORT = 8787;

/**
 * Two end-to-end setups against the production build:
 * - `mock`: the site as committed (empty config.json → in-browser mock backend);
 * - `api`: the site deployed with a config.json pointing at a read API over real HTTP
 *   (scripts/contract-api-server.mjs, CORS limited to the site's origin), as in production.
 */
export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  // The mock backend generates its dataset in the browser (~1 s); several WebGL (SwiftShader)
  // browsers at once make that slower, so allow more time per assertion and fewer workers.
  expect: { timeout: 15_000 },
  workers: 2,
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    trace: "retain-on-failure",
    ...devices["Desktop Chrome"],
    launchOptions: { args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] },
  },
  projects: [
    { name: "mock", use: { baseURL: `http://localhost:${MOCK_PORT}` }, testIgnore: /api-mode\.spec\.ts/ },
    {
      name: "api",
      use: { baseURL: `http://localhost:${API_SITE_PORT}` },
      testMatch: /(smoke|api-mode)\.spec\.ts/,
    },
  ],
  webServer: [
    {
      command: `npm run build && npx vite preview --port ${MOCK_PORT} --strictPort`,
      port: MOCK_PORT,
      reuseExistingServer: !process.env.CI,
      timeout: 180_000,
    },
    {
      command: `node scripts/contract-api-server.mjs --port ${API_PORT} --origin http://localhost:${API_SITE_PORT}`,
      port: API_PORT,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
    },
    {
      // Same build, deployed the way CI deploys it: config.json written next to the site.
      command:
        `npm run build -- --outDir dist-api --emptyOutDir && ` +
        `node -e "require('fs').writeFileSync('dist-api/config.json', JSON.stringify({ apiBase: 'http://localhost:${API_PORT}' }))" && ` +
        `npx vite preview --outDir dist-api --port ${API_SITE_PORT} --strictPort`,
      port: API_SITE_PORT,
      reuseExistingServer: !process.env.CI,
      timeout: 180_000,
    },
  ],
});
