import type { Position } from "@/types/common";

/** Each trip adds this much to a pixel it covers (of 255), so up to 25 overlapping trips are counted exactly. */
const COUNT_STEP = 10;
/** Colour table size, like Strava's 256-colour ramp. */
const RAMP_SIZE = 256;

export interface HeatRasterOptions {
  width: number;
  height: number;
  /** One entry per trip: its lines in pixel coordinates. */
  trips: Position[][][];
  /** Trips the colour scale is fitted to, when that isn't `trips` (a replay keeps the finished map's scale). */
  scaleTrips?: Position[][][];
  /** Line width in device pixels. */
  lineWidth: number;
  /** Glow radius in device pixels (the area of effect under the sharp lines). */
  glow: number;
  /** Colour ramp from few trips to many, as CSS colours (any the canvas understands). */
  ramp: string[];
}

/** The ramp as a 256-entry RGBA table, interpolated in RGB between the stops. */
export function buildRamp(stops: string[]): Uint8ClampedArray {
  const probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  if (!probe) return new Uint8ClampedArray(RAMP_SIZE * 4);
  const rgb = stops.map((stop) => {
    probe.clearRect(0, 0, 1, 1);
    probe.fillStyle = stop;
    probe.fillRect(0, 0, 1, 1);
    const [r, g, b] = probe.getImageData(0, 0, 1, 1).data;
    return [r, g, b];
  });
  const table = new Uint8ClampedArray(RAMP_SIZE * 4);
  for (let i = 0; i < RAMP_SIZE; i++) {
    const position = (i / (RAMP_SIZE - 1)) * (rgb.length - 1);
    const low = Math.min(Math.floor(position), rgb.length - 2);
    const f = position - low;
    for (let c = 0; c < 3; c++) table[i * 4 + c] = rgb[low][c] + (rgb[low + 1][c] - rgb[low][c]) * f;
    // Quiet roads are dimmer, busy ones fully bright.
    table[i * 4 + 3] = 150 + (105 * i) / (RAMP_SIZE - 1);
  }
  return table;
}

/** Draws every trip once with additive blending, so a pixel's value is the number of trips over it x COUNT_STEP. */
function countTrips(width: number, height: number, trips: Position[][][], lineWidth: number): ImageData | null {
  const counts = document.createElement("canvas");
  counts.width = width;
  counts.height = height;
  const countContext = counts.getContext("2d", { willReadFrequently: true });
  if (!countContext) return null;

  countContext.fillStyle = "#000";
  countContext.fillRect(0, 0, width, height);
  countContext.globalCompositeOperation = "lighter";
  countContext.strokeStyle = `rgb(${COUNT_STEP},${COUNT_STEP},${COUNT_STEP})`;
  countContext.lineWidth = lineWidth;
  countContext.lineCap = "round";
  countContext.lineJoin = "round";
  for (const lines of trips) {
    // One path per trip: where a trip crosses itself it still counts once.
    countContext.beginPath();
    for (const line of lines) {
      line.forEach(([x, y], i) => (i === 0 ? countContext.moveTo(x, y) : countContext.lineTo(x, y)));
    }
    countContext.stroke();
  }
  return countContext.getImageData(0, 0, width, height);
}

/** A pixel's value is trips x COUNT_STEP; anti-aliased edge pixels hold less and count as one trip. */
const tripsAt = (value: number) => Math.max(1, Math.round(value / COUNT_STEP));

/** The 95th percentile of the trip counts over the covered pixels, 0 when nothing is covered. */
function countPercentile95(source: ImageData): number {
  const histogram = new Uint32Array(256);
  for (let i = 0; i < source.data.length; i += 4) if (source.data[i] > 0) histogram[tripsAt(source.data[i])]++;
  let covered = 0;
  for (let n = 1; n < 256; n++) covered += histogram[n];
  let seen = 0;
  for (let n = 1; n < 256; n++) {
    seen += histogram[n];
    if (covered > 0 && seen >= covered * 0.95) return n;
  }
  return 0;
}

/**
 * Strava's heat map in miniature: every trip is drawn once with additive blending, so a pixel's value is the number of
 * trips over it; the counts are scaled against what is on screen (log, relative to the 95th percentile, so one busy
 * street doesn't wash out the rest) and coloured through a ramp; a blurred copy underneath gives the glow.
 */
export function renderHeat({ width, height, trips, scaleTrips, lineWidth, glow, ramp }: HeatRasterOptions): HTMLCanvasElement {
  const output = document.createElement("canvas");
  output.width = width;
  output.height = height;
  const outputContext = output.getContext("2d");
  if (!outputContext) return output;

  const source = countTrips(width, height, trips, lineWidth);
  const scaleSource = scaleTrips ? countTrips(width, height, scaleTrips, lineWidth) : source;
  if (!source || !scaleSource) return output;
  const p95 = countPercentile95(scaleSource);
  if (p95 === 0) return output;
  // Log scale from one trip (bottom of the ramp) to the 95th percentile of what is on screen (top).
  const scale = Math.log(Math.max(p95, 2));
  const colored = outputContext.createImageData(width, height);
  const table = buildRamp(ramp);
  for (let i = 0; i < source.data.length; i += 4) {
    if (source.data[i] === 0) continue;
    const t = Math.min(1, Math.max(0.04, Math.log(tripsAt(source.data[i])) / scale));
    const index = Math.round(t * (RAMP_SIZE - 1)) * 4;
    colored.data[i] = table[index];
    colored.data[i + 1] = table[index + 1];
    colored.data[i + 2] = table[index + 2];
    colored.data[i + 3] = table[index + 3];
  }
  const sharp = document.createElement("canvas");
  sharp.width = width;
  sharp.height = height;
  sharp.getContext("2d")?.putImageData(colored, 0, 0);

  outputContext.filter = `blur(${glow}px)`;
  outputContext.globalAlpha = 0.7;
  outputContext.drawImage(sharp, 0, 0);
  outputContext.filter = "none";
  outputContext.globalAlpha = 1;
  outputContext.drawImage(sharp, 0, 0);
  return output;
}
