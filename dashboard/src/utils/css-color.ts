/**
 * Resolves a CSS custom property (e.g. `--scale-1`) to a colour string the canvas libraries
 * (MapLibre, uPlot) understand. Tokens live in global.css, so map/chart colours follow the theme.
 */
export function readCssColor(variable: string, element: Element = document.documentElement): string {
  const value = getComputedStyle(element).getPropertyValue(variable).trim();
  if (!value) return "";
  // Normalize any CSS colour (oklch, color-mix, …) to rgb() through the browser.
  const probe = document.createElement("span");
  probe.style.color = value;
  probe.style.display = "none";
  document.body.appendChild(probe);
  const resolved = getComputedStyle(probe).color;
  probe.remove();
  return resolved || value;
}
