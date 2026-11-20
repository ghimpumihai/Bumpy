/** Where the dashboard reads its data from. `auto` = the API when an API base URL is known, mock data otherwise. */
export const DataSourceMode = {
  AUTO: "auto",
  MOCK: "mock",
  API: "api",
} as const;
export type DataSourceMode = (typeof DataSourceMode)[keyof typeof DataSourceMode];

/** The resolved data source, decided once at startup. */
export type DataSource = { kind: "mock" } | { kind: "api"; apiBase: string };
