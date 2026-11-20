import { keepPreviousData, useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { STATIC_STALE_TIME_MS } from "@/constants";
import type { SegmentCollection, SegmentDetail, VehicleFilter } from "@/types/segments";

export const SEGMENTS_QUERY_KEY = "segments";

const getSegments = async (vehicle: VehicleFilter) =>
  (await api.get<SegmentCollection>("/api/segments", { params: { vehicle } })).data;
const getSegment = async (h3: string) => (await api.get<SegmentDetail>(`/api/segments/${encodeURIComponent(h3)}`)).data;

const useSegments = (vehicle: VehicleFilter) =>
  useQuery({
    queryKey: [SEGMENTS_QUERY_KEY, "list", vehicle],
    queryFn: () => getSegments(vehicle),
    staleTime: STATIC_STALE_TIME_MS,
    // Keep the previous hexagons on screen while another vehicle filter loads.
    placeholderData: keepPreviousData,
  });

const useSegment = (h3: string | undefined) =>
  useQuery({
    queryKey: [SEGMENTS_QUERY_KEY, "detail", h3],
    queryFn: () => getSegment(h3 ?? ""),
    enabled: Boolean(h3),
    staleTime: STATIC_STALE_TIME_MS,
  });

export const segmentsApi = { getSegments, getSegment, useSegments, useSegment };
