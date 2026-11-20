import { useMemo, useSyncExternalStore } from "react";

import { readCssColor } from "@/utils/css-color";

/** The theme lives in `<html class="dark">`; next-themes changes it in an effect, after React renders. */
function subscribeToThemeClass(onChange: () => void) {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "style"] });
  return () => observer.disconnect();
}

const themeClassSnapshot = () => document.documentElement.className;

/**
 * Resolves CSS colour tokens for canvas renderers (MapLibre, uPlot). Colours are read again whenever
 * the root element's class changes, i.e. after the theme was actually applied — reading them when the
 * theme *state* changes would return the previous theme's colours. Pass a stable (module-level) array.
 */
export function useThemeColors<const T extends readonly string[]>(variables: T): Record<T[number], string> {
  const themeClass = useSyncExternalStore(subscribeToThemeClass, themeClassSnapshot, themeClassSnapshot);
  return useMemo(
    () => Object.fromEntries(variables.map((name) => [name, readCssColor(name)])) as Record<T[number], string>,
    // themeClass is the trigger: the CSS variables change with the `dark` class.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [variables, themeClass],
  );
}
