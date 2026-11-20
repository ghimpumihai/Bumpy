import { z } from "zod";

import { DataSourceMode } from "@/types/config";

/** An http(s) URL or "" (no backend); surrounding whitespace from a hand-written config is ignored. */
const httpUrlOrEmpty = z.string().trim().pipe(z.union([z.url({ protocol: /^https?$/ }), z.literal("")]));

/** `/config.json`, written next to the site at deploy time so one build works in every environment. */
export const runtimeConfigSchema = z.object({
  apiBase: httpUrlOrEmpty,
});

/** Override saved by the settings dialog (per browser). */
export const dataSourceOverrideSchema = z.object({
  mode: z.enum(Object.values(DataSourceMode)),
  apiBase: httpUrlOrEmpty,
});

export type DataSourceOverride = z.infer<typeof dataSourceOverrideSchema>;
