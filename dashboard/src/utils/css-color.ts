/**
 * Resolves a CSS custom property (e.g. `--scale-1`) to a colour string the canvas libraries
 * (MapLibre, uPlot) understand. Tokens live in global.css, so map/chart colours follow the theme.
 */
export function readCssColor(variable: string, element: Element = document.documentElement): string {
  const value = getComputedStyle(element).getPropertyValue(variable).trim();
  if (!value) return "";
  // Let the browser resolve var()/color-mix() to a concrete colour (it may stay in oklch(), which
  // MapLibre and canvas both accept).
  const probe = document.createElement("span");
  probe.style.color = value;
  probe.style.display = "none";
  document.body.appendChild(probe);
  const resolved = getComputedStyle(probe).color;
  probe.remove();
  return resolved || value;
}
