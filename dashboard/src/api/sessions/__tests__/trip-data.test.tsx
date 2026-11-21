import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";

import { sessionsApi } from "@/api/sessions";
import type { ProcessingStatus } from "@/types/common";

const get = vi.hoisted(() => vi.fn());
vi.mock("@/config/api-client", () => ({ api: { get } }));

const track = (points: number) => ({
  type: "Feature",
  geometry: { type: "LineString", coordinates: Array.from({ length: points }, (_, i) => [8 + i * 0.001, 47]) },
  properties: { sessionId: "s1", times: [], speeds: [], trimmedM: 0 },
});

const trip = (status: ProcessingStatus) => ({
  sessionId: "s1",
  status,
  startedAt: new Date(Date.now() - 60_000).toISOString(),
  endedAt: status === "live" ? null : new Date().toISOString(),
  durationS: 60,
});

describe("trip data", () => {
  it("is fetched once more when the trip ends, so the last seconds before Stop are not lost", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
    get.mockResolvedValueOnce({ data: track(2) }).mockResolvedValueOnce({ data: track(3) });

    const { result, rerender } = renderHook(({ status }) => sessionsApi.useSessionTrack(trip(status)), {
      wrapper,
      initialProps: { status: "live" as ProcessingStatus },
    });
    await waitFor(() => expect(result.current.data?.geometry.coordinates).toHaveLength(2));

    rerender({ status: "processing" });
    // The previous track stays on screen while the final one loads…
    expect(result.current.data?.geometry.coordinates).toHaveLength(2);
    // …and is replaced by the complete one.
    await waitFor(() => expect(result.current.data?.geometry.coordinates).toHaveLength(3));
    expect(get).toHaveBeenCalledTimes(2);
    client.clear();
  });
});
