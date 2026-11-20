import { PLACEHOLDER } from "@/constants";
import { METERS_PER_KM, MS_TO_KMH } from "@/constants/units";

type NumberInput = number | null | undefined;

const isMissing = (value: NumberInput): value is null | undefined => value === null || value === undefined || !Number.isFinite(value);

const formatters = new Map<number, Intl.NumberFormat>();
function formatter(digits: number) {
  let f = formatters.get(digits);
  if (!f) {
    f = new Intl.NumberFormat("en-GB", { minimumFractionDigits: digits, maximumFractionDigits: digits });
    formatters.set(digits, f);
  }
  return f;
}

export const formatNumber = (value: NumberInput, digits = 0) => (isMissing(value) ? PLACEHOLDER : formatter(digits).format(value));

/** A 0–1 fraction as a percentage: `0.934` → `93 %`. */
export const formatFraction = (value: NumberInput, digits = 0) =>
  isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value * 100)} %`;

/** A value that already is a percentage: `4.2` → `4.2 %`. */
export const formatPercent = (value: NumberInput, digits = 1) => (isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value)} %`);

export const formatDistance = (meters: NumberInput) => {
  if (isMissing(meters)) return PLACEHOLDER;
  return meters >= METERS_PER_KM ? `${formatter(1).format(meters / METERS_PER_KM)} km` : `${formatter(0).format(meters)} m`;
};

export const formatSpeedFromMs = (metersPerSecond: NumberInput) =>
  isMissing(metersPerSecond) ? PLACEHOLDER : `${formatter(0).format(metersPerSecond * MS_TO_KMH)} km/h`;

export const formatKmh = (kmh: NumberInput) => (isMissing(kmh) ? PLACEHOLDER : `${formatter(0).format(kmh)} km/h`);

export const formatAcceleration = (value: NumberInput, digits = 2) =>
  isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value)} m/s²`;

/** MSDV in m/s^1.5. */
export const formatMsdv = (value: NumberInput) => (isMissing(value) ? PLACEHOLDER : `${formatter(2).format(value)} m/s¹·⁵`);

export const formatHz = (value: NumberInput, digits = 1) => (isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value)} Hz`);

export const formatSeconds = (value: NumberInput, digits = 2) => (isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value)} s`);

export const formatMeters = (value: NumberInput, digits = 1) => (isMissing(value) ? PLACEHOLDER : `${formatter(digits).format(value)} m`);
