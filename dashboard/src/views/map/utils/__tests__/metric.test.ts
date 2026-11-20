import { describe, expect, it } from "vitest";

import { ROUGHNESS_BANDS, ROUGHNESS_PERCENTILE_BANDS, SICKNESS_BANDS } from "@/constants/map";
import { metricScale } from "@/views/map/utils/metric";

describe("metricScale", () => {
  it("colours roughness by the model value, or by percentiles when the model wasn't fitted", () => {
    expect(metricScale("roughness", "model")).toMatchObject({ property: "roughness", bands: ROUGHNESS_BANDS });
    expect(metricScale("roughness", undefined)).toMatchObject({ property: "roughness" });
    expect(metricScale("roughness", "percentile")).toMatchObject({ property: "roughnessPctl", bands: ROUGHNESS_PERCENTILE_BANDS });
  });
  it("colours sickness by the predicted incidence whatever the roughness method", () => {
    expect(metricScale("sickness", "percentile")).toMatchObject({ property: "msi1hPct", bands: SICKNESS_BANDS });
  });
});
