import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { AGGREGATE_REFRESH_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import type { QualityListResponse } from "@/types/sessions";

export const QUALITY_QUERY_KEY = "quality";

const getQuality = async () => (await api.get<QualityListResponse>("/api/quality")).data.sessions;

const useQuality = () =>
  useQuery({
    queryKey: [QUALITY_QUERY_KEY],
    queryFn: getQuality,
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
  });

export const qualityApi = { getQuality, useQuality };
