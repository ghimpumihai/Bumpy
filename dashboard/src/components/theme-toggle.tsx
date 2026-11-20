import { Monitor, Moon, Sun } from "lucide-react";
import { useTheme } from "next-themes";

import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

const NEXT_THEME = { system: "light", light: "dark", dark: "system" } as const;
type ThemeName = keyof typeof NEXT_THEME;
const THEME_LABEL: Record<ThemeName, string> = { system: "System theme", light: "Light theme", dark: "Dark theme" };

const isThemeName = (value: string | undefined): value is ThemeName => value !== undefined && value in NEXT_THEME;

export function ThemeToggle() {
  const { theme, setTheme } = useTheme();
  const current: ThemeName = isThemeName(theme) ? theme : "system";
  const Icon = current === "light" ? Sun : current === "dark" ? Moon : Monitor;
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button variant="ghost" size="icon" aria-label={`${THEME_LABEL[current]} (click to change)`} onClick={() => setTheme(NEXT_THEME[current])}>
          <Icon aria-hidden="true" />
        </Button>
      </TooltipTrigger>
      <TooltipContent>{THEME_LABEL[current]}</TooltipContent>
    </Tooltip>
  );
}
