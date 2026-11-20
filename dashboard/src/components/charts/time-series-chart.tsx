import { useEffect, useMemo, useRef } from "react";
import uPlot, { type AlignedData, type Options } from "uplot";

import { MS_PER_SECOND } from "@/constants/units";
import { useThemeColors } from "@/hooks/use-theme-colors";
import { cn } from "@/lib/utils";
import { formatTime } from "@/utils/format-date-time";
import type { ChartSeries } from "@/types/charts";
import type { EpochMs } from "@/types/common";

const AXIS_COLOR_VARS = ["--muted-foreground", "--border"] as const;
const CHART_COLOR_VARS = ["--chart-1", "--chart-2", "--chart-3", "--chart-4", "--chart-5", "--event-pothole", "--event-speed-bump"] as const;
const POINT_SIZE_PX = 7;
const LINE_WIDTH_PX = 1.25;
/** Width before the container is measured (the ResizeObserver corrects it immediately). */
const INITIAL_WIDTH_PX = 600;
const TIME_AXIS_SIZE_PX = 40;
const VALUE_AXIS_SIZE_PX = 56;

interface TimeSeriesChartProps {
  /** Short accessible title, also shown above the chart. */
  title: string;
  /** Epoch milliseconds. */
  times: EpochMs[];
  series: ChartSeries[];
  height?: number;
  /** Charts with the same key share the cursor (uPlot sync). */
  syncKey?: string;
  className?: string;
}

type ColorName = (typeof CHART_COLOR_VARS)[number];

/** uPlot line chart: very fast for long series (plan 02 §5). Resizes with its container. */
export function TimeSeriesChart({ title, times, series, height = 180, syncKey, className }: TimeSeriesChartProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const plotRef = useRef<uPlot | null>(null);
  const axisColors = useThemeColors(AXIS_COLOR_VARS);
  const seriesColors = useThemeColors(CHART_COLOR_VARS);

  const data = useMemo<AlignedData>(() => [times.map((t) => t / MS_PER_SECOND), ...series.map((s) => s.values)], [times, series]);
  const hasRightAxis = series.some((s) => s.axis === "right");
  const structureKey = JSON.stringify([series.map((s) => [s.label, s.colorVar, s.pointsOnly, s.axis, s.unit]), axisColors, seriesColors, height, syncKey]);

  // (Re)build the plot when its structure or the theme changes.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const axis = { stroke: axisColors["--muted-foreground"], grid: { stroke: axisColors["--border"], width: 1 }, ticks: { stroke: axisColors["--border"] } };
    const unitOf = (side: "left" | "right") => series.find((s) => (s.axis ?? "left") === side)?.unit ?? "";
    const options: Options = {
      width: container.clientWidth || INITIAL_WIDTH_PX,
      height,
      cursor: syncKey ? { sync: { key: syncKey } } : {},
      legend: { show: true, live: true },
      scales: { x: { time: true }, y: {}, ...(hasRightAxis ? { y2: {} } : {}) },
      axes: [
        { ...axis, values: (_plot, splits) => splits.map((seconds) => formatTime(seconds * MS_PER_SECOND)), size: TIME_AXIS_SIZE_PX },
        { ...axis, label: unitOf("left"), size: VALUE_AXIS_SIZE_PX },
        ...(hasRightAxis
          ? [{ ...axis, scale: "y2", side: 1 as const, label: unitOf("right"), size: VALUE_AXIS_SIZE_PX, grid: { show: false } }]
          : []),
      ],
      series: [
        {},
        ...series.map((s) => {
          const color = seriesColors[s.colorVar as ColorName] || seriesColors["--chart-1"];
          return {
            label: s.unit ? `${s.label} (${s.unit})` : s.label,
            stroke: color,
            width: s.pointsOnly ? 0 : LINE_WIDTH_PX,
            scale: s.axis === "right" ? "y2" : "y",
            spanGaps: false,
            points: s.pointsOnly ? { show: true, size: POINT_SIZE_PX, fill: color, stroke: color } : { show: false },
          };
        }),
      ],
    };
    const plot = new uPlot(options, data, container);
    plotRef.current = plot;
    const observer = new ResizeObserver(() => plot.setSize({ width: container.clientWidth, height }));
    observer.observe(container);
    return () => {
      observer.disconnect();
      plot.destroy();
      plotRef.current = null;
    };
    // data is pushed by the next effect; rebuilding on every poll would reset zoom and cursor.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [structureKey]);

  // New data (live polling) must not undo the user's zoom: keep the scales while zoomed in.
  useEffect(() => {
    const plot = plotRef.current;
    if (!plot) return;
    const shown = plot.data[0];
    const { min, max } = plot.scales.x;
    const zoomed =
      shown.length > 1 && min !== undefined && max !== undefined && (min > shown[0] || max < shown[shown.length - 1]);
    plot.setData(data, !zoomed);
  }, [data]);

  return (
    <figure className={cn("vertical gap-1", className)}>
      <figcaption className="text-sm font-medium text-foreground">{title}</figcaption>
      <div ref={containerRef} className="w-full text-xs text-muted-foreground" role="img" aria-label={title} />
    </figure>
  );
}
