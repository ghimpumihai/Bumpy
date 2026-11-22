import { AnimatePresence, motion } from "motion/react";
import { useState } from "react";

import { liveApi } from "@/api/live";
import { ErrorAlert } from "@/components/error-alert";
import { LIVE_API_STALE_MS } from "@/constants";
import { QueryState } from "@/components/query-state";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";

import { LiveDeviceCard } from "./components/live-device-card";
import { LiveMap } from "./components/live-map";
import { liveFreshness } from "./utils/freshness";
import { StreamStatus } from "@/types/sessions";
import { CARD_ANIMATION_OFFSET_PX, CARD_ANIMATION_S } from "./utils/constants";

export function LiveView() {
  const live = liveApi.useLive();
  const now = useNow();
  const devices = live.data?.devices ?? [];
  // The phone the map follows; `nonce` changes on every pick, so picking the same one again flies back to it.
  const [focus, setFocus] = useState<{ sessionId: string | undefined; nonce: number }>({ sessionId: undefined, nonce: 0 });
  const unfollow = () => setFocus((previous) => ({ ...previous, sessionId: undefined }));
  const toggleFollow = (sessionId: string) =>
    setFocus((previous) => (previous.sessionId === sessionId ? { ...previous, sessionId: undefined } : { sessionId, nonce: previous.nonce + 1 }));
  // Ages are measured on the server's clock: offset = server time − local time at the last response.
  const clockOffsetMs = live.data ? Date.parse(live.data.serverTime) - live.dataUpdatedAt : 0;
  // If the dashboard can't reach the read API, the cards must not blame the phones for the silence.
  const apiUnreachable = live.data !== undefined && (live.isError || now - live.dataUpdatedAt > LIVE_API_STALE_MS);
  const serverNow = now + clockOffsetMs;
  const stale = new Set(devices.filter((device) => apiUnreachable || liveFreshness(device, serverNow).status !== StreamStatus.OK).map((device) => device.sessionId));
  return (
    <div className="grid flex-1 grid-rows-[minmax(22rem,1fr)_auto] lg:grid-cols-[1fr_24rem] lg:grid-rows-1">
      <div className="relative min-h-[22rem]">
        <LiveMap devices={devices} stale={stale} focus={focus} onUnfollow={unfollow} />
      </div>
      <aside aria-label="Streaming devices" className="vertical gap-3 overflow-y-auto border-t p-4 lg:border-t-0 lg:border-l">
        <div className="vertical gap-1">
          <h1 className="text-lg font-semibold">Live</h1>
        </div>
        {apiUnreachable && (
          <ErrorAlert
            title="Live data"
            error={live.error ?? new Error("The read API hasn't answered for a few seconds; the cards show the last data received.")}
            onRetry={() => void live.refetch()}
          />
        )}
        <QueryState
          isPending={live.isPending}
          error={apiUnreachable ? null : live.error}
          hasData={live.data !== undefined}
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
                <LiveDeviceCard
                  device={device}
                  now={serverNow}
                  apiUnreachable={apiUnreachable}
                  following={focus.sessionId === device.sessionId}
                  onToggleFollow={() => toggleFollow(device.sessionId)}
                />
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
