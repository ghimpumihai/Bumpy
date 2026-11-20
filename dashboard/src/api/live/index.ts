import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { LIVE_POLL_INTERVAL_MS } from "@/constants";
import type { LiveResponse } from "@/types/live";

export const LIVE_QUERY_KEY = "live";

const getLive = async () => (await api.get<LiveResponse>("/api/live")).data;

const useLive = () =>
  useQuery({
    queryKey: [LIVE_QUERY_KEY],
    queryFn: getLive,
    refetchInterval: LIVE_POLL_INTERVAL_MS,
    // Keep polling when the tab is in the background on the presentation laptop.
    refetchIntervalInBackground: true,
    staleTime: 0,
  });

export const liveApi = { getLive, useLive };
