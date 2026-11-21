import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { test as setup } from "@playwright/test";

const SEED = fileURLToPath(new URL("./real-api/seed.py", import.meta.url));

// Seeded right before the tests: the live view only lists devices heard from in the last 60 s.
setup("seed the database through the processor's write path", () => {
  const python = process.env.REAL_API_PYTHON;
  if (!python) throw new Error("REAL_API_PYTHON is not set");
  execFileSync(python, [SEED], { stdio: "inherit", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" } });
});
