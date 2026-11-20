import { useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { STATIC_STALE_TIME_MS } from "@/constants";
import type { Overview } from "@/types/overview";

export const OVERVIEW_QUERY_KEY = "overview";

const getOverview = async () => (await api.get<Overview>("/api/overview")).data;

const useOverview = () =>
  useQuery({ queryKey: [OVERVIEW_QUERY_KEY], queryFn: getOverview, staleTime: STATIC_STALE_TIME_MS });

export const overviewApi = { getOverview, useOverview };
