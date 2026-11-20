import { keepPreviousData, useQuery } from "@tanstack/react-query";

import { api } from "@/config/api-client";
import { AGGREGATE_REFRESH_INTERVAL_MS, STATIC_STALE_TIME_MS } from "@/constants";
import type { RoadEventCollection } from "@/types/sessions";
import type { VehicleFilter } from "@/types/segments";
import { expectShape, shapes } from "@/utils/api-shape";

export const EVENTS_QUERY_KEY = "events";

const EVENTS_ROUTE = "/api/events";
const getEvents = async (vehicle: VehicleFilter) =>
  expectShape<RoadEventCollection>((await api.get<unknown>(EVENTS_ROUTE, { params: { vehicle } })).data, EVENTS_ROUTE, shapes.featureCollection);

/** Detected events of every aggregated session (replays and live-only sessions excluded by the API). */
const useEvents = (vehicle: VehicleFilter) =>
  useQuery({
    queryKey: [EVENTS_QUERY_KEY, vehicle],
    queryFn: () => getEvents(vehicle),
    staleTime: STATIC_STALE_TIME_MS,
    refetchInterval: AGGREGATE_REFRESH_INTERVAL_MS,
    placeholderData: keepPreviousData,
  });

export const eventsApi = { getEvents, useEvents };
