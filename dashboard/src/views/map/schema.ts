import { z } from "zod";


/** Type-safe search params of `/map` (the aggregated map), so every view is shareable as a link. */
export const mapSearchSchema = z.object({
  events: z.boolean().default(true).catch(true),
  segment: z.string().optional().catch(undefined),
});

export type MapSearch = z.infer<typeof mapSearchSchema>;
