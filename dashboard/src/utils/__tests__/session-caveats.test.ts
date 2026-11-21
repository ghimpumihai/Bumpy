import { describe, expect, it } from "vitest";

import type { ExclusionReason } from "@/types/sessions";
import { sicknessCaveat } from "@/utils/session-caveats";

const caveat = (sicknessExperimental: boolean, exclusionReasons: ExclusionReason[]) => sicknessCaveat({ sicknessExperimental, exclusionReasons });

describe("sicknessCaveat", () => {
  it("names the real reason, and never calls an unknown mount 'not rigid'", () => {
    expect(caveat(true, ["unknown_context", "live_only"])).toBe("Experimental: mount unknown");
    expect(caveat(true, ["not_rigid"])).toBe("Experimental: mount not rigid");
    expect(caveat(true, ["handheld", "not_rigid"])).toBe("Experimental: hand-held");
    expect(caveat(true, [])).toBe("Experimental");
  });
  it("has no caveat for a rigid, known mount", () => {
    expect(caveat(false, ["live_only"])).toBeNull();
  });
});
