import { afterEach, describe, expect, it } from "vitest";

import { readCssColor } from "@/utils/css-color";

describe("readCssColor", () => {
  afterEach(() => document.documentElement.style.removeProperty("--test-color"));

  it("resolves a CSS custom property through the browser", () => {
    document.documentElement.style.setProperty("--test-color", "rgb(1, 2, 3)");
    expect(readCssColor("--test-color")).toBe("rgb(1, 2, 3)");
  });
  it("returns an empty string for an unknown token", () => {
    expect(readCssColor("--does-not-exist")).toBe("");
  });
});
