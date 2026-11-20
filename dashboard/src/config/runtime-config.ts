import axios from "axios";

import { env } from "@/config/env";
import { dataSourceOverrideSchema, runtimeConfigSchema, type DataSourceOverride } from "@/config/schema";
import { DATA_SOURCE_SESSION_KEY, DATA_SOURCE_STORAGE_KEY, MOCK_QUERY_PARAM, RUNTIME_CONFIG_PATH, RUNTIME_CONFIG_TIMEOUT_MS } from "@/constants";
import { DataSourceMode, type DataSource } from "@/types/config";

/** The API was chosen explicitly but no API URL is known: fail visibly instead of showing mock data. */
export class MissingApiBaseError extends Error {
  constructor() {
    super(
      "The read API was selected (?mock=0, the settings dialog or VITE_DATA_SOURCE=api) but no API URL is configured: config.json has an empty apiBase.",
    );
    this.name = "MissingApiBaseError";
  }
}

/** The deployed /config.json is missing, unreachable or invalid: a broken deploy must not quietly show mock data. */
export class RuntimeConfigError extends Error {
  constructor(detail: string) {
    super(`The site's /config.json could not be used (${detail}). Check the deploy that writes it.`);
    this.name = "RuntimeConfigError";
  }
}

function safeStorage<T>(read: () => T, fallback: T): T {
  try {
    return read();
  } catch {
    // Storage can be unavailable (private mode, blocked cookies); behave as if nothing were stored.
    return fallback;
  }
}

export function readDataSourceOverride(): DataSourceOverride | null {
  return safeStorage(() => {
    const raw = window.localStorage.getItem(DATA_SOURCE_STORAGE_KEY);
    if (!raw) return null;
    const parsed = dataSourceOverrideSchema.safeParse(JSON.parse(raw));
    return parsed.success ? parsed.data : null;
  }, null);
}

/**
 * Saves (or clears) the browser's data-source choice and reloads without `?mock=`, which would otherwise
 * win over the saved choice, and without the tab's remembered `?mock=` value.
 */
export function applyDataSourceOverride(value: DataSourceOverride | null) {
  safeStorage(() => {
    if (value) window.localStorage.setItem(DATA_SOURCE_STORAGE_KEY, JSON.stringify(value));
    else window.localStorage.removeItem(DATA_SOURCE_STORAGE_KEY);
    window.sessionStorage.removeItem(DATA_SOURCE_SESSION_KEY);
  }, undefined);
  const url = new URL(window.location.href);
  url.searchParams.delete(MOCK_QUERY_PARAM);
  window.location.replace(url);
}

/** `?mock=1` / `?mock=0`, remembered for the tab so in-app navigation (which drops it) doesn't switch the source. */
function forcedMode(search: string): DataSourceMode | null {
  const fromUrl = new URLSearchParams(search).get(MOCK_QUERY_PARAM);
  const value = fromUrl ?? safeStorage(() => window.sessionStorage.getItem(DATA_SOURCE_SESSION_KEY), null);
  if (fromUrl !== null) safeStorage(() => window.sessionStorage.setItem(DATA_SOURCE_SESSION_KEY, fromUrl), undefined);
  if (value === "1") return DataSourceMode.MOCK;
  if (value === "0") return DataSourceMode.API;
  return null;
}

/** Reads /config.json. Only a valid file with an empty apiBase means "no backend": anything else is an error. */
async function fetchRuntimeApiBase(): Promise<string> {
  let data: unknown;
  try {
    const response = await axios.get<unknown>(RUNTIME_CONFIG_PATH, {
      headers: { "Cache-Control": "no-cache" },
      timeout: RUNTIME_CONFIG_TIMEOUT_MS,
    });
    data = response.data;
  } catch (error) {
    throw new RuntimeConfigError(axios.isAxiosError(error) ? (error.response ? `HTTP ${error.response.status}` : error.message) : String(error));
  }
  const parsed = runtimeConfigSchema.safeParse(data);
  if (!parsed.success) throw new RuntimeConfigError("apiBase must be an http(s) URL or empty");
  return parsed.data.apiBase;
}

const stripTrailingSlash = (url: string) => url.replace(/\/+$/, "");

/**
 * Precedence: `?mock=` (remembered for the tab) → settings override → `VITE_DATA_SOURCE` → API if a base URL
 * is known, else mock. Throws `MissingApiBaseError` when the API is required explicitly but has no URL, and
 * `RuntimeConfigError` when the deployed config.json is broken.
 */
export async function resolveDataSource(search: string = window.location.search): Promise<DataSource> {
  const override = readDataSourceOverride();
  const mode = forcedMode(search) ?? override?.mode ?? env.VITE_DATA_SOURCE;
  if (mode === DataSourceMode.MOCK) return { kind: "mock" };

  const apiBase = override?.apiBase || env.VITE_API_BASE || (await fetchRuntimeApiBase());
  if (apiBase) return { kind: "api", apiBase: stripTrailingSlash(apiBase) };
  if (mode === DataSourceMode.API) throw new MissingApiBaseError();
  return { kind: "mock" };
}
