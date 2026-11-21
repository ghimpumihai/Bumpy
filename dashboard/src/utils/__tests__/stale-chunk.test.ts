import { describe, expect, it } from "vitest";

import { isStaleChunkError } from "@/utils/stale-chunk";

describe("isStaleChunkError", () => {
  it("recognises a lazy chunk that is gone after a redeploy, in every browser's wording", () => {
    expect(isStaleChunkError(new TypeError("Failed to fetch dynamically imported module: https://x/assets/live-abc.js"))).toBe(true);
    expect(isStaleChunkError(new TypeError("error loading dynamically imported module: https://x/assets/live-abc.js"))).toBe(true);
    expect(isStaleChunkError(new TypeError("Importing a module script failed."))).toBe(true);
    expect(isStaleChunkError(new Error("Unable to preload CSS for /assets/live-abc.css"))).toBe(true);
  });
  it("leaves other errors alone", () => {
    expect(isStaleChunkError(new Error("Request failed with status code 500"))).toBe(false);
    expect(isStaleChunkError("boom")).toBe(false);
  });
});
