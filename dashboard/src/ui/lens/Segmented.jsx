import React, { useEffect } from "react";
import { motion, useSpring, useTransform } from "motion/react";
import { SPRING_BOUNCY } from "../../motion/presets";

/**
 * 分段控件。轨道 999px、内边距 2px，指示器按几何比例定位，
 * 位移由弹簧驱动（SPRING_BOUNCY），切换带可见的过冲与回咬。
 *
 * @param {{
 *   options: Array<{ value: string, label: string }>,
 *   value: string,
 *   onChange: (value: string) => void,
 *   ariaLabel: string,
 *   size?: "sm" | "md"
 * }} props
 */
export function Segmented({ options, value, onChange, ariaLabel, size = "md" }) {
  const activeIndex = Math.max(
    0,
    options.findIndex((option) => option.value === value)
  );
  const total = Math.max(options.length, 1);
  const height = size === "sm" ? "h-7" : "h-8";

  const step = useSpring(activeIndex, SPRING_BOUNCY);
  useEffect(() => {
    step.set(activeIndex);
  }, [activeIndex, step]);
  const translate = useTransform(step, (v) => `translateX(${v * 100}%)`);

  return (
    <div
      role="tablist"
      aria-label={ariaLabel}
      className={`relative inline-flex ${height} items-stretch rounded-pill bg-[var(--lens-fill-hover)] p-[2px]`}
      style={{ "--lens-seg-count": total, "--lens-seg-index": activeIndex }}
    >
      <motion.span
        aria-hidden
        className="absolute bottom-[2px] left-[2px] top-[2px] rounded-pill bg-surface-2 shadow-sm"
        style={{
          width: `calc((100% - 4px) / ${total})`,
          transform: translate
        }}
      />
      {options.map((option) => {
        const active = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            role="tab"
            aria-selected={active}
            onClick={() => onChange(option.value)}
            className={`relative z-10 inline-flex flex-1 items-center justify-center whitespace-nowrap px-2.5 text-caption transition-colors duration-fast ease-lens ${
              active ? "font-medium text-ink" : "text-ink-muted hover:text-ink-secondary"
            }`}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}
