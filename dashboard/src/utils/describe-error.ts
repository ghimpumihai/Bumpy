import { isAxiosError } from "axios";

/** A short, user-readable description of a failed request. */
export function describeError(error: unknown): string {
  if (isAxiosError(error)) {
    const status = error.response?.status;
    const body = error.response?.data as { error?: unknown } | undefined;
    const detail = typeof body?.error === "string" ? body.error : error.message;
    if (status === 404) return `Not found: ${detail}`;
    if (status) return `HTTP ${status}: ${detail}`;
    return `The read API could not be reached (${error.message}).`;
  }
  return error instanceof Error ? error.message : String(error);
}
