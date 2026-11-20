import { z } from "zod";

import { SessionSource, VehicleType } from "@/types/common";

export const ANY_FILTER = "any";

export const sessionsSearchSchema = z.object({
  source: z.enum([ANY_FILTER, ...Object.values(SessionSource)]).default(ANY_FILTER).catch(ANY_FILTER),
  vehicle: z.enum([ANY_FILTER, ...Object.values(VehicleType)]).default(ANY_FILTER).catch(ANY_FILTER),
});

export type SessionsSearch = z.infer<typeof sessionsSearchSchema>;
