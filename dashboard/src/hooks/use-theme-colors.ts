import { useTheme } from "next-themes";
import { useMemo } from "react";

import { readCssColor } from "@/utils/css-color";

/**
 * Resolves CSS colour tokens for canvas renderers; recomputed when the theme changes.
 * Pass a stable (module-level) array of variable names.
 */
export function useThemeColors<const T extends readonly string[]>(variables: T): Record<T[number], string> {
  const { resolvedTheme } = useTheme();
  return useMemo(
    () => Object.fromEntries(variables.map((name) => [name, readCssColor(name)])) as Record<T[number], string>,
    // resolvedTheme is the trigger: the CSS variables change with the `dark` class.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [variables, resolvedTheme],
  );
}
