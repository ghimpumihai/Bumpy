import { z } from "zod";

import { DEFAULT_REPLAY_SPEED, REPLAY_SPEEDS } from "./utils/constants";


/** Type-safe search params of `/map` (the aggregated map), so every view is shareable as a link. */
export const mapSearchSchema = z.object({
  events: z.boolean().default(true).catch(true),
  /** Pace of the trip replay, a multiple of the recorded one. */
  speed: z.literal(REPLAY_SPEEDS).default(DEFAULT_REPLAY_SPEED).catch(DEFAULT_REPLAY_SPEED),
  segment: z.string().optional().catch(undefined),
});

export type MapSearch = z.infer<typeof mapSearchSchema>;
