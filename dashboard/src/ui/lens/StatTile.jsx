import React from "react";

/**
 * 指标块。数值用等宽数字，label 走 micro 大写，单位与说明压在下面一行。
 *
 * @param {{ label: string, value: React.ReactNode, unit?: string, hint?: React.ReactNode,
 *           emphasis?: boolean }} props
 */
export function StatTile({ label, value, unit, hint, emphasis = false }) {
  return (
    <div className="flex flex-col gap-1 px-4 py-3">
      <div className="text-micro font-medium uppercase tracking-wider text-ink-muted">{label}</div>
      <div className="flex items-baseline gap-1">
        <span
          className={`tabular ${emphasis ? "text-display font-semibold" : "text-title font-medium"} text-ink`}
        >
          {value}
        </span>
        {unit ? <span className="text-caption text-ink-muted">{unit}</span> : null}
      </div>
      {hint ? <div className="text-caption text-ink-muted">{hint}</div> : null}
    </div>
  );
}

/**
 * 一组指标块，用发丝线分隔，外框由 Card 提供。
 *
 * @param {{ children: React.ReactNode, columns?: 2|3|4 }} props
 */
export function StatRow({ children, columns = 4 }) {
  const cols =
    columns === 2 ? "sm:grid-cols-2" : columns === 3 ? "sm:grid-cols-3" : "sm:grid-cols-2 lg:grid-cols-4";
  return (
    <div className={`grid grid-cols-1 divide-y divide-line-soft sm:divide-x sm:divide-y-0 ${cols}`}>
      {children}
    </div>
  );
}
