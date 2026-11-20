import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { AGGREGATE_REFRESH_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import type { QualityListResponse } from "@/types/sessions";
import { expectShape, shapes } from "@/utils/api-shape";

export const QUALITY_QUERY_KEY = "quality";

const QUALITY_ROUTE = "/api/quality";
const getQuality = async () =>
  expectShape<QualityListResponse>((await api.get<unknown>(QUALITY_ROUTE)).data, QUALITY_ROUTE, shapes.quality).sessions;

const useQuality = () =>
  useQuery({
    queryKey: [QUALITY_QUERY_KEY],
    queryFn: getQuality,
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
  });

export const qualityApi = { getQuality, useQuality };
