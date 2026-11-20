import { AnimatePresence, motion } from "motion/react";

import { liveApi } from "@/api/live";
import { QueryState } from "@/components/query-state";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";

import { LiveDeviceCard } from "./components/live-device-card";
import { LiveMap } from "./components/live-map";
import { CARD_ANIMATION_OFFSET_PX, CARD_ANIMATION_S } from "./utils/constants";

export function LiveView() {
  const live = liveApi.useLive();
  const now = useNow();
  const devices = live.data?.devices ?? [];
  // Ages are measured on the server's clock: offset = server time − local time at the last response.
  const clockOffsetMs = live.data ? Date.parse(live.data.serverTime) - live.dataUpdatedAt : 0;
  return (
    <div className="grid flex-1 grid-rows-[minmax(22rem,1fr)_auto] lg:grid-cols-[1fr_24rem] lg:grid-rows-1">
      <div className="relative min-h-[22rem]">
        <LiveMap devices={devices} />
      </div>
      <aside aria-label="Streaming devices" className="vertical gap-3 overflow-y-auto border-t p-4 lg:border-t-0 lg:border-l">
        <div className="vertical gap-1">
          <h1 className="text-lg font-semibold">Live</h1>
          <p className="text-xs text-muted-foreground">
            Phones and replays streaming through the live path to the read API. Refreshes every 2 s.
          </p>
        </div>
        <QueryState
          isPending={live.isPending}
          error={live.error}
          onRetry={() => void live.refetch()}
          skeleton={<Skeleton className="h-36 w-full" />}
        >
          {/* Kept mounted when the list empties, so the last card can animate out too. */}
          <AnimatePresence initial={false} mode="popLayout">
            {devices.map((device) => (
              // Phones appear and disappear as they start and stop streaming.
              <motion.div
                key={device.deviceId}
                layout
                initial={{ opacity: 0, y: CARD_ANIMATION_OFFSET_PX }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -CARD_ANIMATION_OFFSET_PX }}
                transition={{ duration: CARD_ANIMATION_S }}
              >
                <LiveDeviceCard device={device} now={now + clockOffsetMs} />
              </motion.div>
            ))}
            {devices.length === 0 && (
              <motion.p
                key="empty"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground"
              >
                No phone is streaming right now. Start a recording with live upload enabled, or re-send a recorded trip with{" "}
                <code className="rounded bg-muted px-1">tools/replay</code>.
              </motion.p>
            )}
          </AnimatePresence>
        </QueryState>
      </aside>
    </div>
  );
}
