import { liveApi } from "@/api/live";
import { QueryState } from "@/components/query-state";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";

import { LiveDeviceCard } from "./components/live-device-card";
import { LiveMap } from "./components/live-map";

export function LiveView() {
  const live = liveApi.useLive();
  const now = useNow();
  const devices = live.data?.devices ?? [];
  return (
    <div className="grid flex-1 grid-rows-[minmax(22rem,1fr)_auto] lg:grid-cols-[1fr_24rem] lg:grid-rows-1">
      <div className="relative min-h-[22rem]">
        <LiveMap devices={devices} />
      </div>
      <aside aria-label="Streaming devices" className="vertical gap-3 overflow-y-auto border-t p-4 lg:border-t-0 lg:border-l">
        <div className="vertical gap-1">
          <h1 className="text-lg font-semibold">Live</h1>
          <p className="text-xs text-muted-foreground">
            Phones and replays streaming through the live path (API Gateway → Kinesis → stream processor). Refreshes every 2 s.
          </p>
        </div>
        <QueryState
          isPending={live.isPending}
          error={live.error}
          onRetry={() => void live.refetch()}
          isEmpty={devices.length === 0}
          emptyMessage={
            <span>
              No phone is streaming right now. Start a recording with live upload enabled, or re-send a recorded trip with{" "}
              <code className="rounded bg-muted px-1">tools/replay</code>.
            </span>
          }
          skeleton={<Skeleton className="h-36 w-full" />}
        >
          {devices.map((device) => (
            <LiveDeviceCard key={device.deviceId} device={device} now={now} />
          ))}
        </QueryState>
      </aside>
    </div>
  );
}
