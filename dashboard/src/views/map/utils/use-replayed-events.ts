import { useMemo } from "react";

import type { RoadEventCollection } from "@/types/sessions";

import type { TripReplay } from "./use-trip-replay";

/** During a replay, only the events already driven over; otherwise all of them. */
export function useReplayedEvents(events: RoadEventCollection | undefined, { active, trips, index, frame }: TripReplay): RoadEventCollection | undefined {
  const ordered = useMemo(() => {
    const order = new Map(trips.map((trip, i) => [trip.sessionId, i]));
    return (events?.features ?? [])
      .flatMap((feature) => {
        const trip = order.get(feature.properties.sessionId);
        return trip === undefined ? [] : [{ feature, trip, time: Date.parse(feature.properties.tUtc) }];
      })
      .sort((a, b) => a.trip - b.trip || a.time - b.time);
  }, [events, trips]);
  const time = frame?.time ?? -Infinity;
  const count = ordered.filter((event) => event.trip < index || (event.trip === index && event.time <= time)).length;
  // Keyed by the count: the map gets a new collection only when an event appears, not on every frame.
  const shown = useMemo<RoadEventCollection>(
    () => ({ type: "FeatureCollection", features: ordered.slice(0, count).map((event) => event.feature) }),
    [ordered, count],
  );
  return active && events ? shown : events;
}
