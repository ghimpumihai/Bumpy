import axios from "axios";
import { z } from "zod";

import { env } from "@/config/env";
import { DATA_SOURCE_STORAGE_KEY, MOCK_QUERY_PARAM, RUNTIME_CONFIG_PATH } from "@/constants";
import { DataSourceMode, type DataSource } from "@/types/config";

const httpUrlOrEmpty = z.union([z.url({ protocol: /^https?$/ }), z.literal("")]);

/** `/config.json`, written next to the site at deploy time so one build works in every environment. */
const runtimeConfigSchema = z.object({
  apiBase: httpUrlOrEmpty.default(""),
});

/** Override saved by the settings dialog (per browser). */
export const dataSourceOverrideSchema = z.object({
  mode: z.enum(Object.values(DataSourceMode)),
  apiBase: httpUrlOrEmpty,
});

/** The API was chosen explicitly but no API URL is known: fail visibly instead of showing mock data. */
export class MissingApiBaseError extends Error {
  constructor() {
    super(
      "The read API was selected (?mock=0, the settings dialog or VITE_DATA_SOURCE=api) but no API URL is configured: config.json has an empty apiBase.",
    );
    this.name = "MissingApiBaseError";
  }
}
export type DataSourceOverride = z.infer<typeof dataSourceOverrideSchema>;

export function readDataSourceOverride(): DataSourceOverride | null {
  try {
    const raw = window.localStorage.getItem(DATA_SOURCE_STORAGE_KEY);
    if (!raw) return null;
    const parsed = dataSourceOverrideSchema.safeParse(JSON.parse(raw));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

export function writeDataSourceOverride(value: DataSourceOverride | null) {
  try {
    if (value) window.localStorage.setItem(DATA_SOURCE_STORAGE_KEY, JSON.stringify(value));
    else window.localStorage.removeItem(DATA_SOURCE_STORAGE_KEY);
  } catch {
    // Storage can be unavailable (private mode); the override then simply does not persist.
  }
}

async function fetchRuntimeApiBase(): Promise<string> {
  try {
    const response = await axios.get<unknown>(RUNTIME_CONFIG_PATH, { headers: { "Cache-Control": "no-cache" } });
    const parsed = runtimeConfigSchema.safeParse(response.data);
    return parsed.success ? parsed.data.apiBase : "";
  } catch {
    return "";
  }
}

const stripTrailingSlash = (url: string) => url.replace(/\/+$/, "");

/**
 * Precedence: `?mock=` → settings override → `VITE_DATA_SOURCE` → API if a base URL is known, else mock.
 * Throws `MissingApiBaseError` when the API is required explicitly but has no URL.
 */
export async function resolveDataSource(search: string = window.location.search): Promise<DataSource> {
  const override = readDataSourceOverride();
  const queryValue = new URLSearchParams(search).get(MOCK_QUERY_PARAM);
  const mode =
    queryValue === "1" ? DataSourceMode.MOCK : queryValue === "0" ? DataSourceMode.API : (override?.mode ?? env.VITE_DATA_SOURCE);
  if (mode === DataSourceMode.MOCK) return { kind: "mock" };

  const apiBase = override?.apiBase || env.VITE_API_BASE || (await fetchRuntimeApiBase());
  if (apiBase) return { kind: "api", apiBase: stripTrailingSlash(apiBase) };
  if (mode === DataSourceMode.API) throw new MissingApiBaseError();
  return { kind: "mock" };
}
