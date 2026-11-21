import { expect, test, type Page } from "@playwright/test";

// Seeded by e2e/real-api/seed.py.
const LIVE = "e2e00000-0000-4000-8000-00000000live";
const ENDED = "e2e00000-0000-4000-8000-0000000ended";
const NO_CONTEXT = "e2e00000-0000-4000-8000-00000context";
const API_ORIGIN = "http://localhost:8788";

function trackErrors(page: Page) {
  const errors: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("GL Driver Message")) errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(String(error)));
  return errors;
}

test("every page renders against the real read API, without errors and without the mock", async ({ page }) => {
  const errors = trackErrors(page);
  page.on("request", (request) => {
    if (request.url().includes("mock-adapter")) errors.push(`mock loaded: ${request.url()}`);
  });
  for (const path of ["/live", "/map", "/sessions", "/quality", "/method", `/sessions/${ENDED}`]) {
    await page.goto(path);
    // The live and map pages are full-screen (no page heading): wait for the page's own content.
    await expect(page.locator("#content")).toBeVisible();
    await page.waitForLoadState("networkidle");
    await expect(page.getByText(/could not be loaded|could not be reached|unexpected answer/i)).toHaveCount(0);
  }
  expect(errors).toEqual([]);
});

test("the live view shows the phone that is recording, polled from the real API", async ({ page }) => {
  let polls = 0;
  page.on("request", (request) => {
    if (request.url() === `${API_ORIGIN}/api/live`) polls += 1;
  });
  await page.goto("/live");
  const panel = page.getByRole("complementary", { name: "Streaming devices" });
  await expect(panel.locator(`a[href$="/sessions/${LIVE}"]`)).toBeVisible();
  await expect.poll(() => polls, { timeout: 10_000 }).toBeGreaterThanOrEqual(3);
});

test("the sessions list shows each trip's real state", async ({ page }) => {
  await page.goto("/sessions");
  for (const id of [LIVE, ENDED, NO_CONTEXT]) await expect(page.locator(`a[href$="/sessions/${id}"]`).first()).toBeVisible();
});

test("an ended trip reads as processing, with its track and context", async ({ page }) => {
  await page.goto(`/sessions/${ENDED}`);
  const header = page.locator("header", { has: page.getByRole("heading", { level: 1 }) });
  await expect(header.getByText("Processing", { exact: true })).toBeVisible();
  await expect(page.getByText("Solaris Urbino 12, line 24")).toBeVisible();
  await expect(page.locator(".maplibregl-canvas").first()).toBeVisible();
});

test("a trip without session.json says its context is unknown instead of inventing one", async ({ page }) => {
  await page.goto(`/sessions/${NO_CONTEXT}`);
  await expect(page.getByText("unknown (session.json not received)").first()).toBeVisible();
  await expect(page.getByText("Experimental: mount unknown")).toBeVisible();
  await expect(page.getByText("(not rigid)")).toHaveCount(0);
});
