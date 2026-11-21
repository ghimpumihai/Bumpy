import { createEnv } from "@t3-oss/env-core";
import { z } from "zod";

/** Build-time settings. The deployed site is configured at runtime through `/config.json` instead. */
export const env = createEnv({
  clientPrefix: "VITE_",
  client: {
    /** Read API base URL for local development, e.g. `http://localhost:8000`. */
    VITE_API_BASE: z.url().optional(),
  },
  runtimeEnv: import.meta.env,
  emptyStringAsUndefined: true,
});
