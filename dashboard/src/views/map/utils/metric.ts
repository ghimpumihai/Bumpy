import { ROUGHNESS_BANDS, ROUGHNESS_PERCENTILE_BANDS, SICKNESS_BANDS } from "@/constants/map";
import type { MapMetric, ScaleBand } from "@/types/map";
import type { RoughnessMethod, SegmentAggregate } from "@/types/segments";

export interface MetricScale {
  /** Property of `SegmentAggregate` that colours the hexagon. */
  property: keyof Pick<SegmentAggregate, "roughness" | "roughnessPctl" | "msi1hPct">;
  bands: ScaleBand[];
  title: string;
  footnote: string;
}

/** Which aggregate and colour bands a metric uses; roughness falls back to percentiles when the model could not be fitted. */
export function metricScale(metric: MapMetric, method: RoughnessMethod | undefined): MetricScale {
  if (metric === "sickness") {
    return {
      property: "msi1hPct",
      bands: SICKNESS_BANDS,
      title: "Motion sickness (ISO 2631-1)",
      footnote: "Predicted share of passengers who may vomit after one hour of this motion (MSDV / 3). Not normalized: it is what passengers feel.",
    };
  }
  if (method === "percentile") {
    return {
      property: "roughnessPctl",
      bands: ROUGHNESS_PERCENTILE_BANDS,
      title: "Road roughness (percentile)",
      footnote: "Too little overlap between vehicles to fit the model: mean per-session percentile of raw roughness.",
    };
  }
  return {
    property: "roughness",
    bands: ROUGHNESS_BANDS,
    title: "Road roughness",
    footnote: "Vertical RMS (1–30 Hz) a reference car would feel at 36 km/h, normalized across vehicles and speeds.",
  };
}
