import { expect, test, type Page } from "@playwright/test";

const RECORDED_SESSION = "3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11";

/** Fails the test on any console error or uncaught exception (e.g. a MapLibre worker that cannot load). */
function trackErrors(page: Page) {
  const errors: string[] = [];
  page.on("console", (message) => {
    // Swiftshader performance notices are not errors of the app.
    if (message.type() === "error" && !message.text().includes("GL Driver Message")) errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(String(error)));
  return errors;
}

test("the start page is the live view (plan 02 §5)", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveURL(/\/live$/);
  await expect(page.getByRole("link", { name: "Live" })).toHaveAttribute("aria-current", "page");
});

test("map shows the aggregated segments and the overview", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto("/map");
  await expect(page.getByRole("region", { name: "Dataset overview" })).toContainText("Confirmed potholes");
  await expect(page.getByRole("region", { name: /Map of road segments/ })).toBeVisible();
  await expect(page.locator(".maplibregl-canvas")).toBeVisible();
  await expect(page.getByRole("region", { name: "Road roughness legend" })).toBeVisible();

  await page.getByRole("radio", { name: "Motion sickness" }).click();
  await expect(page).toHaveURL(/metric=sickness/);
  await expect(page.getByRole("region", { name: /Motion sickness .* legend/ })).toBeVisible();
  expect(errors).toEqual([]);
});

test("sessions list links to a session with its data-quality panel", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto("/sessions");
  await expect(page.getByRole("heading", { name: "Sessions" })).toBeVisible();
  const rows = page.getByRole("row");
  await expect(rows).toHaveCount(20); // header + 19 mock sessions
  await expect(page.getByText("Incomplete").first()).toBeVisible();
  await expect(page.getByText("Replay").first()).toBeVisible();

  await page.goto(`/sessions/${RECORDED_SESSION}`);
  await expect(page.getByText("Detection vs. manual taps")).toBeVisible();
  await expect(page.locator("#content").getByText("Data quality", { exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Device motion" })).toBeVisible();
  await expect(page.getByRole("region", { name: /Map of this trip/ })).toBeVisible();
  expect(errors).toEqual([]);
});

test("unknown session shows a not-found error instead of crashing", async ({ page }) => {
  await page.goto("/sessions/does-not-exist");
  await expect(page.getByRole("alert")).toContainText("Not found");
});

test("live view lists the streaming phone and the replay", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto("/live");
  const panel = page.getByRole("complementary", { name: "Streaming devices" });
  // Badges, matched exactly: the panel's description also mentions "replays".
  await expect(panel.locator('[data-slot="badge"]', { hasText: /^Replay$/ })).toBeVisible();
  await expect(panel.locator('[data-slot="badge"]', { hasText: /^Streamed$/ })).toBeVisible();
  // The real end-to-end delay is shown, not just "live" (plan 02 §5).
  await expect(panel.getByText(/behind the phone|catching up|no data for/).first()).toBeVisible();
  await expect(panel.getByText("Latest MISC").first()).toBeVisible();
  expect(errors).toEqual([]);
});

test("data quality and method pages render", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto("/quality");
  await expect(page.getByRole("heading", { name: "Data quality" })).toBeVisible();
  await expect(page.getByText("Degraded").first()).toBeVisible();
  await page.getByRole("link", { name: "Method" }).click();
  await expect(page.getByRole("heading", { name: "How it works" })).toBeVisible();
  await expect(page.getByText(/speed exponent β =/)).toBeVisible();
  expect(errors).toEqual([]);
});

test("session page draws the synchronized charts", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto(`/sessions/${RECORDED_SESSION}`);
  await expect(page.getByRole("img", { name: /Vertical acceleration/ })).toBeVisible();
  await expect(page.locator(".uplot")).toHaveCount(4);
  await expect(page.getByText("Prediction vs. passenger ratings")).toBeVisible();
  expect(errors).toEqual([]);
});

test("the data-source dialog saves a choice and reloads with it, even from a ?mock= URL", async ({ page }) => {
  await page.goto("/sessions?mock=1");
  await page.getByRole("button", { name: /data source settings/ }).click();
  const dialog = page.getByRole("dialog", { name: "Data source" });
  // Pick the API with a half-typed URL first, then switch to mock: saving must still work.
  await dialog.getByRole("combobox", { name: "Source" }).click();
  await page.getByRole("option", { name: /Read API at this URL/ }).click();
  await dialog.getByLabel(/API base URL/).fill("http://half-typ");
  await dialog.getByRole("combobox", { name: "Source" }).click();
  await page.getByRole("option", { name: /Mock data/ }).click();
  await Promise.all([page.waitForEvent("load"), dialog.getByRole("button", { name: "Save and reload" }).click()]);
  const saved = await page.evaluate(() => window.localStorage.getItem("dashboard.data-source"));
  expect(JSON.parse(saved ?? "null")).toEqual({ mode: "mock", apiBase: "" });
  await expect(page.getByRole("button", { name: /Mock data: data source settings/ })).toBeVisible();
  // ?mock= would win over the saved choice, so the reload drops it.
  expect(new URL(page.url()).searchParams.has("mock")).toBe(false);
});

test("deep links load directly (Static Web Apps falls back to index.html)", async ({ page }) => {
  const response = await page.goto(`/sessions/${RECORDED_SESSION}`);
  expect(response?.status()).toBe(200);
  await expect(page.getByText("Detection vs. manual taps")).toBeVisible();
});

test("forcing the API without an API URL explains the problem instead of showing mock data", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name === "api", "the API-mode site has an API URL in config.json");
  await page.goto("/sessions?mock=0");
  await expect(page.getByRole("alert")).toContainText("no API URL is configured");
  await page.getByRole("button", { name: "Reset data source and reload" }).click();
  await expect(page.getByRole("heading", { name: "Sessions" })).toBeVisible();
});

test("a trip being processed updates by itself once it is finalized and joins the map", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name === "api", "the stand-in API's clock is not controlled by the browser");
  const RECENTLY_ENDED = "5e8c1a7d-2b9f-4c63-a0d4-8f1e3b6c9a21";
  await page.clock.install();
  await page.goto(`/sessions/${RECENTLY_ENDED}`);
  const header = page.locator("header", { has: page.getByRole("heading", { level: 1 }) });
  await expect(header.getByText("Processing", { exact: true })).toBeVisible();
  await expect(page.getByText(/Not counted in the aggregated map: Not finalized yet/)).toBeVisible();
  // The finalize job finishes a few minutes after the trip ended; the page polls until then.
  await page.clock.fastForward("05:00");
  await page.clock.runFor(10_000);
  await expect(header.getByText("Processing", { exact: true })).toBeHidden();
  await expect(page.getByText(/Not counted in the aggregated map/)).toBeHidden();
});
