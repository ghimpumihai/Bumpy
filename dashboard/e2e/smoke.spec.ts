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

test("map shows the aggregated segments and the overview", async ({ page }) => {
  const errors = trackErrors(page);
  await page.goto("/");
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
  await expect(rows).toHaveCount(18); // header + 17 mock sessions
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
  // Badges, matched exactly: the panel's description also mentions "replays" and "live".
  await expect(panel.locator('[data-slot="badge"]', { hasText: /^Replay$/ })).toBeVisible();
  await expect(panel.locator('[data-slot="badge"]', { hasText: /^Live$/ })).toBeVisible();
  await expect(panel.getByText(/updated \d+ s ago/).first()).toBeVisible();
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

test("the data-source dialog saves a choice and reloads with it", async ({ page }) => {
  await page.goto("/sessions");
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
});

test("forcing the API without an API URL explains the problem instead of showing mock data", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name === "api", "the API-mode site has an API URL in config.json");
  await page.goto("/sessions?mock=0");
  await expect(page.getByRole("alert")).toContainText("no API URL is configured");
  await page.getByRole("button", { name: "Reset data source and reload" }).click();
  await expect(page.getByRole("heading", { name: "Sessions" })).toBeVisible();
});
