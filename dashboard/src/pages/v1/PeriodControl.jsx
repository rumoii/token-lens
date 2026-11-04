import React, { useRef, useState } from "react";
import { CalendarDays } from "lucide-react";
import { CustomRangePopover } from "../../ui/lens/DateRange.jsx";
import { Segmented } from "../../ui/lens/Segmented.jsx";

/**
 * 首页页头右侧的周期切换：今天 / 本周 / 本月 / 全部 / 自定义。概览和明细共用。
 *
 * @param {{ period: { period: string }, range: { from: string|null, to: string|null },
 *           onChange: (next: { period: string, from?: string, to?: string }) => void }} props
 */
export function PeriodControl({ period, range, onChange }) {
  const [customOpen, setCustomOpen] = useState(false);
  const wrapRef = useRef(null);

  const pick = (value) => {
    setCustomOpen(false);
    if (value === "custom") {
      setCustomOpen(true);
      return;
    }
    onChange({ period: value });
  };

  return (
    <div ref={wrapRef} className="relative">
      <Segmented
        ariaLabel="周期"
        value={period.period}
        onChange={pick}
        options={[
          { value: "today", label: "今天" },
          { value: "week", label: "本周" },
          { value: "month", label: "本月" },
          { value: "all", label: "全部" },
          {
            value: "custom",
            label: (
              <span className="inline-flex items-center">
                <CalendarDays className="h-3.5 w-3.5" aria-hidden />
                <span className="sr-only">自定义</span>
              </span>
            )
          }
        ]}
      />
      {customOpen ? (
        <CustomRangePopover
          range={{ from: range.from || "", to: range.to || "" }}
          onChange={({ from, to }) => onChange({ period: "custom", from, to })}
          onClose={() => setCustomOpen(false)}
          containerRef={wrapRef}
        />
      ) : null}
    </div>
  );
}

/**
 * 概览 / 明细。两个视图在同一个地址下，切换时周期不变。
 *
 * @param {{ view: "overview"|"detail", onChange: (view: string) => void }} props
 */
export function ViewSwitch({ view, onChange }) {
  return (
    <Segmented
      ariaLabel="视图"
      value={view}
      onChange={onChange}
      options={[
        { value: "overview", label: "概览" },
        { value: "detail", label: "明细" }
      ]}
    />
  );
}
