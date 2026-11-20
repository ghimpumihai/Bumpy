import { QueryClient } from "@tanstack/react-query";
import { isAxiosError } from "axios";

import { DEFAULT_GC_TIME_MS, QUERY_RETRY_COUNT } from "@/constants";

const HTTP_CLIENT_ERROR_MIN = 400;
const HTTP_SERVER_ERROR_MIN = 500;

/** A 4xx (unknown session, bad filter) will not change on retry; network errors and 5xx might. */
export function shouldRetry(failureCount: number, error: unknown): boolean {
  if (failureCount >= QUERY_RETRY_COUNT) return false;
  const status = isAxiosError(error) ? error.response?.status : undefined;
  return status === undefined || status < HTTP_CLIENT_ERROR_MIN || status >= HTTP_SERVER_ERROR_MIN;
}

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: shouldRetry, gcTime: DEFAULT_GC_TIME_MS, refetchOnWindowFocus: false },
    },
  });
}
