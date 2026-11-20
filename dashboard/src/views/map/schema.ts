import { z } from "zod";

import { MapMetric } from "@/types/map";
import { VehicleFilter } from "@/types/segments";

/** Type-safe search params of `/map` (the aggregated map), so every view is shareable as a link. */
export const mapSearchSchema = z.object({
  metric: z.enum(Object.values(MapMetric)).default(MapMetric.ROUGHNESS).catch(MapMetric.ROUGHNESS),
  vehicle: z.enum(Object.values(VehicleFilter)).default(VehicleFilter.ALL).catch(VehicleFilter.ALL),
  events: z.boolean().default(true).catch(true),
  segment: z.string().optional().catch(undefined),
});

export type MapSearch = z.infer<typeof mapSearchSchema>;
