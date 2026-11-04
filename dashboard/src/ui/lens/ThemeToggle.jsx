import React from "react";
import { Monitor, Moon, Sun } from "lucide-react";
import { copy } from "../../lib/copy";
import { useTheme } from "../../hooks/useTheme";
import { Segmented } from "./Segmented.jsx";

const OPTIONS = [
  { value: "light", icon: Sun, key: "preference.theme.light" },
  { value: "dark", icon: Moon, key: "preference.theme.dark" },
  { value: "system", icon: Monitor, key: "preference.theme.system" }
];

/**
 * 主题切换。三个选项用分段控件，当前项由滑块位置表达，不再各画一个按钮。
 */
export function ThemeToggle() {
  const { theme, setTheme } = useTheme();

  return (
    <div className="flex items-center gap-2">
      <Segmented
        ariaLabel={copy("preference.theme.system")}
        size="sm"
        value={theme}
        onChange={setTheme}
        options={OPTIONS.map((option) => ({
          value: option.value,
          label: copy(option.key)
        }))}
      />
    </div>
  );
}

/**
 * 图标形态，给窄屏或空间不足处使用。
 */
export function ThemeIcons() {
  const { theme, setTheme } = useTheme();
  return (
    <div className="flex items-center gap-1">
      {OPTIONS.map(({ value, icon: Icon, key }) => {
        const active = theme === value;
        const label = copy(key);
        return (
          <button
            key={value}
            type="button"
            onClick={() => setTheme(value)}
            aria-pressed={active}
            aria-label={label}
            title={label}
            className={`inline-flex h-7 w-7 items-center justify-center rounded-md transition-colors duration-fast ease-lens ${
              active ? "bg-surface-2 text-clay shadow-sm" : "text-ink-muted hover:text-ink"
            }`}
          >
            <Icon className="h-4 w-4" aria-hidden />
          </button>
        );
      })}
    </div>
  );
}
