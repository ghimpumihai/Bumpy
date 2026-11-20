import { expect, test } from "@playwright/test";

const API_ORIGIN = "http://localhost:8787";

test("reads config.json and talks to the read API over HTTP, without loading the mock", async ({ page }) => {
  const apiRequests: string[] = [];
  const mockChunks: string[] = [];
  page.on("request", (request) => {
    if (request.url().startsWith(API_ORIGIN)) apiRequests.push(new URL(request.url()).pathname);
    if (request.url().includes("mock-adapter")) mockChunks.push(request.url());
  });
  await page.goto("/");
  await expect(page.getByRole("button", { name: /Read API: data source settings/ })).toBeVisible();
  await expect(page.getByRole("region", { name: "Dataset overview" })).toContainText("Confirmed potholes");
  expect(apiRequests).toEqual(expect.arrayContaining(["/api/overview", "/api/segments", "/api/events"]));
  expect(mockChunks).toEqual([]);
});

test("the live view keeps polling the read API", async ({ page }) => {
  let livePolls = 0;
  page.on("request", (request) => {
    if (request.url() === `${API_ORIGIN}/api/live`) livePolls += 1;
  });
  await page.goto("/live");
  const panel = page.getByRole("complementary", { name: "Streaming devices" });
  await expect(panel.locator('[data-slot="badge"]', { hasText: /^Replay$/ })).toBeVisible();
  await expect.poll(() => livePolls, { timeout: 10_000 }).toBeGreaterThanOrEqual(3);
});

test("?mock=1 still forces mock data on a deployed site", async ({ page }) => {
  await page.goto("/sessions?mock=1");
  await expect(page.getByRole("button", { name: /Mock data: data source settings/ })).toBeVisible();
});
