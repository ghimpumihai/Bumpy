import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { useThemeColors } from "@/hooks/use-theme-colors";

vi.mock("@/utils/css-color", () => ({
  // The colour depends on the theme class actually applied to <html>, like real CSS variables.
  readCssColor: (name: string) => `${document.documentElement.classList.contains("dark") ? "dark" : "light"}${name}`,
}));

const VARS = ["--card"] as const;

describe("useThemeColors", () => {
  afterEach(() => document.documentElement.classList.remove("dark"));

  it("re-reads colours after the theme class changes, not before", async () => {
    const { result } = renderHook(() => useThemeColors(VARS));
    expect(result.current["--card"]).toBe("light--card");
    // next-themes applies the class in an effect, after React rendered with the new theme state.
    await act(async () => {
      document.documentElement.classList.add("dark");
      await Promise.resolve();
    });
    expect(result.current["--card"]).toBe("dark--card");
  });
});
