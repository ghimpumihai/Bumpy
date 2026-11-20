import { AxeBuilder } from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

const ROUTES = ["/live", "/map", "/sessions", "/sessions/3f1c2b9e-0d4a-4e7b-9c51-6a2d8e0f4b11", "/quality", "/method"];
const WCAG_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"];

for (const colorScheme of ["light", "dark"] as const) {
  test.describe(`WCAG 2.1 AA (${colorScheme})`, () => {
    test.use({ colorScheme });
    for (const route of ROUTES) {
      test(`no violations on ${route}`, async ({ page }) => {
        await page.goto(route);
        await expect(page.locator("#content")).not.toBeEmpty();
        // Let queries settle so the scan sees real content, not skeletons.
        await page.waitForLoadState("networkidle").catch(() => undefined);
        await expect(page.locator('[data-slot="skeleton"]')).toHaveCount(0);
        // The WebGL canvas has no DOM text to check; its controls and legends are checked.
        const result = await new AxeBuilder({ page }).withTags(WCAG_TAGS).exclude(".maplibregl-canvas").analyze();
        expect(result.violations.map((violation) => `${violation.id}: ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`)).toEqual([]);
      });
    }
  });
}
