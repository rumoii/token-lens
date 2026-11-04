import React, { useEffect, useRef, useState } from "react";
import { Calendar, Check } from "lucide-react";
import { Button } from "./Button.jsx";

/** 预设区间：`days` 为回看天数，`null` 表示全部。 */
const PRESETS = [
  { id: "today", label: "今天", days: 1 },
  { id: "7d", label: "近 7 天", days: 7 },
  { id: "30d", label: "近 30 天", days: 30 },
  { id: "all", label: "全部", days: null }
];

/** @param {number} days */
function isoDaysAgo(days) {
  const date = new Date();
  date.setDate(date.getDate() - (days - 1));
  return date.toISOString().slice(0, 10);
}

/**
 * 把预设换算成 `from`/`to`。`to` 留空表示到今天为止。
 *
 * @param {string} presetId
 * @returns {{ from: string, to: string }}
 */
export function rangeOfPreset(presetId) {
  const preset = PRESETS.find((p) => p.id === presetId);
  if (!preset || preset.days === null) return { from: "", to: "" };
  return { from: isoDaysAgo(preset.days), to: "" };
}

/**
 * 当前区间对应的预设 id；自定义区间返回 null。
 *
 * @param {{ from: string, to: string }} range
 */
export function presetOf(range) {
  if (!range.from && !range.to) return "all";
  if (range.to) return null;
  for (const preset of PRESETS) {
    if (preset.days && range.from === isoDaysAgo(preset.days)) return preset.id;
  }
  return null;
}

/**
 * 区间跨度（天）。`to` 为空表示到今天；两端都空表示全部时间，返回 null（无界）。
 *
 * @param {{ from: string, to: string }} range
 * @returns {number|null}
 */
export function spanDaysOf(range) {
  if (!range.from && !range.to) return null;
  const start = range.from ? Date.parse(range.from) : NaN;
  if (Number.isNaN(start)) return null;
  const end = range.to ? Date.parse(range.to) : Date.now();
  return Math.max(1, Math.floor((end - start) / 86400000) + 1);
}

/**
 * 范围驱动的默认粒度：单日按小时，90 天内按日，更长按月。
 *
 * @param {{ from: string, to: string }} range
 * @returns {"hour"|"day"|"month"}
 */
export function granularityForRange(range) {
  const days = spanDaysOf(range);
  if (days === null) return "month";
  if (days <= 1) return "hour";
  return days <= 90 ? "day" : "month";
}

/**
 * 自定义区间弹出层：两个日期输入 + 清空 / 应用。挂在自己的触发器下面，
 * 点外部或按 Esc 关闭。首页的周期分段也复用这一块。
 *
 * @param {{
 *   range: { from: string, to: string },
 *   onChange: (range: { from: string, to: string }) => void,
 *   onClose: () => void,
 *   containerRef?: { current: HTMLElement|null }
 * }} props
 */
export function CustomRangePopover({ range, onChange, onClose, containerRef }) {
  const [draft, setDraft] = useState(range);
  const wrapRef = useRef(null);

  useEffect(() => {
    const onDown = (event) => {
      const anchor = containerRef?.current;
      if (wrapRef.current?.contains(event.target) || anchor?.contains(event.target)) return;
      onClose();
    };
    const onKey = (event) => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  return (
    <div
      ref={wrapRef}
      className="absolute right-0 z-40 mt-1.5 w-64 rounded-xl bg-surface-2 p-3 shadow-popover"
      style={{ animation: "lens-fade-in 120ms var(--lens-ease) both" }}
    >
      <label className="block text-micro font-medium uppercase tracking-wider text-ink-muted">
        起始
        <input
          type="date"
          value={draft.from}
          max={draft.to || undefined}
          onChange={(event) => setDraft((prev) => ({ ...prev, from: event.target.value }))}
          className="mt-1 h-8 w-full rounded-lg bg-surface-1 px-2 text-caption text-ink outline-none focus-visible:ring-1 focus-visible:ring-clay"
        />
      </label>
      <label className="mt-2 block text-micro font-medium uppercase tracking-wider text-ink-muted">
        结束
        <input
          type="date"
          value={draft.to}
          min={draft.from || undefined}
          onChange={(event) => setDraft((prev) => ({ ...prev, to: event.target.value }))}
          className="mt-1 h-8 w-full rounded-lg bg-surface-1 px-2 text-caption text-ink outline-none focus-visible:ring-1 focus-visible:ring-clay"
        />
      </label>
      <div className="mt-3 flex items-center justify-between">
        <Button variant="ghost" size="xs" onClick={() => setDraft({ from: "", to: "" })}>
          清空
        </Button>
        <Button
          variant="primary"
          size="xs"
          onClick={() => {
            onChange(draft);
            onClose();
          }}
        >
          <Check className="h-3 w-3" aria-hidden />
          应用
        </Button>
      </div>
    </div>
  );
}

/**
 * 时间范围选择。预设在一行，自定义收在浮层里。
 *
 * @param {{
 *   range: { from: string, to: string },
 *   onChange: (range: { from: string, to: string }) => void
 * }} props
 */
export function DateRange({ range, onChange }) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);
  const active = presetOf(range);

  const label = range.from || range.to
    ? `${range.from || "最早"} → ${range.to || "今天"}`
    : "全部时间";

  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <div className="inline-flex items-center gap-1 rounded-pill bg-[var(--lens-fill-hover)] p-[2px]">
        {PRESETS.map((preset) => (
          <button
            key={preset.id}
            type="button"
            aria-pressed={active === preset.id}
            onClick={() => onChange(rangeOfPreset(preset.id))}
            className={`h-7 rounded-pill px-2.5 text-caption transition-colors duration-fast ease-lens ${
              active === preset.id
                ? "bg-surface-2 font-medium text-ink shadow-sm"
                : "text-ink-muted hover:text-ink-secondary"
            }`}
          >
            {preset.label}
          </button>
        ))}
      </div>

      <div className="relative" ref={wrapRef}>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => setOpen((value) => !value)}
          aria-expanded={open}
        >
          <Calendar className="h-3.5 w-3.5" aria-hidden />
          {label}
        </Button>

        {open ? (
          <CustomRangePopover
            range={range}
            onChange={onChange}
            onClose={() => setOpen(false)}
            containerRef={wrapRef}
          />
        ) : null}
      </div>
    </div>
  );
}
