import { defineConfig, devices } from "@playwright/test";

const PORT = 4173;

/** Smoke tests against the production build (vite preview), with the built-in mock data. */
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
    baseURL: `http://localhost:${PORT}`,
    trace: "retain-on-failure",
    ...devices["Desktop Chrome"],
    launchOptions: { args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"] },
  },
  webServer: {
    command: `npm run build && npx vite preview --port ${PORT} --strictPort`,
    port: PORT,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
