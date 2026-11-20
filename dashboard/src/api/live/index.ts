import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { LIVE_POLL_INTERVAL_MS, LIVE_REQUEST_TIMEOUT_MS } from "@/constants";
import type { LiveResponse } from "@/types/live";
import { expectShape, shapes } from "@/utils/api-shape";

export const LIVE_QUERY_KEY = "live";

const LIVE_ROUTE = "/api/live";
const getLive = async () =>
  expectShape<LiveResponse>((await api.get<unknown>(LIVE_ROUTE, { timeout: LIVE_REQUEST_TIMEOUT_MS })).data, LIVE_ROUTE, shapes.live);

const useLive = () =>
  useQuery({
    queryKey: [LIVE_QUERY_KEY],
    queryFn: getLive,
    refetchInterval: LIVE_POLL_INTERVAL_MS,
    // Keep polling when the tab is in the background on the presentation laptop.
    refetchIntervalInBackground: true,
    staleTime: 0,
    // Polling is the retry: a stalled request must surface quickly, not after the general timeout
    // and two retries (~48 s of stale cards on bad Wi-Fi).
    retry: false,
  });

export const liveApi = { getLive, useLive };
