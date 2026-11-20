import dayjs from "dayjs";
import duration from "dayjs/plugin/duration";
import relativeTime from "dayjs/plugin/relativeTime";

import { PLACEHOLDER } from "@/constants";
import { DATE_FORMAT, DATE_TIME_FORMAT, TIME_FORMAT } from "@/constants/date-time";
import { MS_PER_SECOND, SECONDS_PER_MINUTE } from "@/constants/units";

dayjs.extend(duration);
dayjs.extend(relativeTime);

type DateInput = string | number | Date | null | undefined;

const isMissing = (value: DateInput): value is null | undefined => value === null || value === undefined || value === "";

/** Local time of the viewer, e.g. `21 Nov 2026, 09:12`. */
export const formatDateTime = (value: DateInput) => (isMissing(value) ? PLACEHOLDER : dayjs(value).format(DATE_TIME_FORMAT));
export const formatDate = (value: DateInput) => (isMissing(value) ? PLACEHOLDER : dayjs(value).format(DATE_FORMAT));
export const formatTime = (value: DateInput) => (isMissing(value) ? PLACEHOLDER : dayjs(value).format(TIME_FORMAT));

/** `1 h 05 min`, `12 min 30 s`, `45 s`. */
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return PLACEHOLDER;
  const d = dayjs.duration(Math.max(0, Math.round(seconds)), "seconds");
  const hours = Math.floor(d.asHours());
  if (hours > 0) return `${hours} h ${String(d.minutes()).padStart(2, "0")} min`;
  if (d.minutes() > 0) return `${d.minutes()} min ${String(d.seconds()).padStart(2, "0")} s`;
  return `${d.seconds()} s`;
}

/** `5 s ago`, `3 minutes ago`, relative to `now`. */
export function formatAge(value: DateInput, now: number = Date.now()): string {
  if (isMissing(value)) return PLACEHOLDER;
  const seconds = Math.max(0, Math.round((now - dayjs(value).valueOf()) / MS_PER_SECOND));
  if (seconds < SECONDS_PER_MINUTE) return `${seconds} s ago`;
  return dayjs(value).from(now);
}
