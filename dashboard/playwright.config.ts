import { defineConfig, devices } from "@playwright/test";

const MOCK_PORT = 4173;
const API_SITE_PORT = 4176;
const API_PORT = 8787;
const REAL_API_SITE_PORT = 4177;
const REAL_API_PORT = 8788;
/**
 * Python with services/read-api + services/processor requirements, and libpq variables (PGHOST, …) for a
 * PostGIS database: enables the `real-api` project (the real FastAPI read API, seeded through the
 * processor's write path). CI sets it in .github/workflows/dashboard-ci.yml.
 */
const REAL_API_PYTHON = process.env.REAL_API_PYTHON;

/**
 * Two end-to-end setups against the production build:
 * - `mock`: the site as committed (empty config.json → in-browser mock backend);
 * - `api`: the site deployed with a config.json pointing at a read API over real HTTP
 *   (scripts/contract-api-server.mjs, CORS limited to the site's origin), as in production;
 * - `real-api` (only with REAL_API_PYTHON): the same against services/read-api itself on a seeded PostGIS,
 *   so what only the mock does (trip states, privacy, empty context) can't hide a mismatch.
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
    { name: "mock", use: { baseURL: `http://localhost:${MOCK_PORT}` }, testIgnore: /(api-mode|real-api)\.spec\.ts/ },
    {
      name: "api",
      use: { baseURL: `http://localhost:${API_SITE_PORT}` },
      testMatch: /(smoke|api-mode)\.spec\.ts/,
    },
    ...(REAL_API_PYTHON
      ? [
          { name: "real-api-seed", testMatch: /real-api\.setup\.ts/ },
          {
            name: "real-api",
            use: { baseURL: `http://localhost:${REAL_API_SITE_PORT}` },
            testMatch: /real-api\.spec\.ts/,
            dependencies: ["real-api-seed"],
          },
        ]
      : []),
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
    ...(REAL_API_PYTHON
      ? [
          {
            command: `${REAL_API_PYTHON} -m uvicorn --app-dir ../services/read-api app.main:app --port ${REAL_API_PORT}`,
            port: REAL_API_PORT,
            reuseExistingServer: !process.env.CI,
            timeout: 60_000,
            env: { CORS_ALLOWED_ORIGINS: `http://localhost:${REAL_API_SITE_PORT}`, PYTHONDONTWRITEBYTECODE: "1" },
          },
          {
            command:
              `npm run build -- --outDir dist-real-api --emptyOutDir && ` +
              `node -e "require('fs').writeFileSync('dist-real-api/config.json', JSON.stringify({ apiBase: 'http://localhost:${REAL_API_PORT}' }))" && ` +
              `npx vite preview --outDir dist-real-api --port ${REAL_API_SITE_PORT} --strictPort`,
            port: REAL_API_SITE_PORT,
            reuseExistingServer: !process.env.CI,
            timeout: 180_000,
          },
        ]
      : []),
  ],
});
