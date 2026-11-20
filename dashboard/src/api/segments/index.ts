import { keepPreviousData, useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { AGGREGATE_REFRESH_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import type { SegmentCollection, SegmentDetail, VehicleFilter } from "@/types/segments";
import { expectShape, shapes } from "@/utils/api-shape";

export const SEGMENTS_QUERY_KEY = "segments";

const SEGMENTS_ROUTE = "/api/segments";
const getSegments = async (vehicle: VehicleFilter) =>
  expectShape<SegmentCollection>((await api.get<unknown>(SEGMENTS_ROUTE, { params: { vehicle } })).data, SEGMENTS_ROUTE, shapes.featureCollection);
const getSegment = async (h3: string) => {
  const route = `${SEGMENTS_ROUTE}/${encodeURIComponent(h3)}`;
  return expectShape<SegmentDetail>((await api.get<unknown>(route)).data, route, shapes.segmentDetail);
};

const useSegments = (vehicle: VehicleFilter) =>
  useQuery({
    queryKey: [SEGMENTS_QUERY_KEY, "list", vehicle],
    queryFn: () => getSegments(vehicle),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
    // Keep the previous hexagons on screen while another vehicle filter loads.
    placeholderData: keepPreviousData,
  });

const useSegment = (h3: string | undefined) =>
  useQuery({
    queryKey: [SEGMENTS_QUERY_KEY, "detail", h3],
    queryFn: () => getSegment(h3 ?? ""),
    enabled: Boolean(h3),
    staleTime: STATIC_STALE_TIME_MS,
    // Keeps the last segment on screen while the panel animates closed or switches segment.
    placeholderData: keepPreviousData,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
  });

export const segmentsApi = { getSegments, getSegment, useSegments, useSegment };
