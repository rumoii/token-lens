import React from "react";

/**
 * 空态。一句话说清楚「为什么没有」和「下一步做什么」。
 *
 * @param {{ title: string, hint?: React.ReactNode, action?: React.ReactNode }} props
 */
export function EmptyState({ title, hint, action }) {
  return (
    <div className="flex flex-col items-center gap-2 rounded-panel px-6 py-10 text-center">
      <p className="text-body font-medium text-ink-secondary">{title}</p>
      {hint ? <p className="max-w-sm text-caption text-ink-muted">{hint}</p> : null}
      {action ? <div className="mt-1">{action}</div> : null}
    </div>
  );
}

/**
 * 加载态：三条占位横线，带扫光，不做旋转指示器。
 * 扫光在 `prefers-reduced-motion: reduce` 下自动停（见 styles.css）。
 */
export function SkeletonLines({ rows = 3 }) {
  return (
    <div className="space-y-2 py-1" aria-hidden>
      {Array.from({ length: rows }).map((_, index) => (
        <div
          key={index}
          className="lens-skeleton h-3 rounded-sm bg-[var(--lens-fill-hover)]"
          style={{ width: `${88 - index * 14}%` }}
        />
      ))}
    </div>
  );
}
