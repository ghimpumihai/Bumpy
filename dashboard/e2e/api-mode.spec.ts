import { expect, test } from "@playwright/test";

const API_ORIGIN = "http://localhost:8787";

test("reads config.json and talks to the read API over HTTP, without loading the mock", async ({ page }) => {
  const apiRequests: string[] = [];
  const mockChunks: string[] = [];
  page.on("request", (request) => {
    if (request.url().startsWith(API_ORIGIN)) apiRequests.push(new URL(request.url()).pathname);
    if (request.url().includes("mock-adapter")) mockChunks.push(request.url());
  });
  await page.goto("/map");
  await expect(page.getByRole("button", { name: /Read API: data source settings/ })).toBeVisible();
  await expect(page.getByRole("region", { name: "Dataset overview" })).toContainText("Potholes");
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
  await expect(panel.getByText(/^Replay ·/)).toBeVisible();
  await expect.poll(() => livePolls, { timeout: 10_000 }).toBeGreaterThanOrEqual(3);
});

test("?mock=1 still forces mock data on a deployed site", async ({ page }) => {
  await page.goto("/sessions?mock=1");
  await expect(page.getByRole("button", { name: /Mock data: data source settings/ })).toBeVisible();
});

test("a wrong API URL that answers with an HTML page shows a clear error on every page, never a crash", async ({ page }) => {
  await page.route(`${API_ORIGIN}/**`, (route) =>
    route.fulfill({ status: 200, contentType: "text/html", headers: { "access-control-allow-origin": "*" }, body: "<!doctype html><title>x</title>" }),
  );
  for (const path of ["/map", "/sessions", "/sessions/3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11", "/live"]) {
    await page.goto(path);
    await expect(page.getByText(/instead of JSON\. Check the API URL/).first(), path).toBeVisible();
    await expect(page.getByText("Something went wrong!"), path).toHaveCount(0);
  }
});

test("when the read API stops answering, the live view says so instead of blaming the phones", async ({ page }) => {
  await page.goto("/live");
  const panel = page.getByRole("complementary", { name: "Streaming devices" });
  await expect(panel.getByText(/behind the phone|catching up/).first()).toBeVisible();
  await page.route(`${API_ORIGIN}/api/live`, (route) => route.abort("connectionrefused"));
  await expect(panel.getByRole("alert")).toContainText("Live data could not be loaded");
  await expect(panel.getByText(/^last data \d\d:\d\d:\d\d$/).first()).toBeVisible();
  await expect(panel.getByText(/no data for/)).toHaveCount(0);
});
