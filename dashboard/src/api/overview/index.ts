import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { AGGREGATE_REFRESH_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import type { Overview } from "@/types/overview";
import { expectShape, shapes } from "@/utils/api-shape";

export const OVERVIEW_QUERY_KEY = "overview";

const OVERVIEW_ROUTE = "/api/overview";
const getOverview = async () => expectShape<Overview>((await api.get<unknown>(OVERVIEW_ROUTE)).data, OVERVIEW_ROUTE, shapes.overview);

const useOverview = () =>
  useQuery({
    queryKey: [OVERVIEW_QUERY_KEY],
    queryFn: getOverview,
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
  });

export const overviewApi = { getOverview, useOverview };
