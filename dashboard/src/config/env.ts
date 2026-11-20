import { createEnv } from "@t3-oss/env-core";
import { z } from "zod";

import { DataSourceMode } from "@/types/config";

/** Build-time settings. The deployed site is configured at runtime through `/config.json` instead. */
export const env = createEnv({
  clientPrefix: "VITE_",
  client: {
    /** Read API base URL for local development, e.g. `http://localhost:8000`. */
    VITE_API_BASE: z.url().optional(),
    VITE_DATA_SOURCE: z.enum(Object.values(DataSourceMode)).default(DataSourceMode.AUTO),
  },
  runtimeEnv: import.meta.env,
  emptyStringAsUndefined: true,
});
