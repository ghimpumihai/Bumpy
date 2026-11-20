import { useEffect, useState } from "react";

import { MS_PER_SECOND } from "@/constants/units";

/** Current time, refreshed every `intervalMs`, for "updated 3 s ago" labels. */
export function useNow(intervalMs: number = MS_PER_SECOND): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}
