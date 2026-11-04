import React from "react";

/**
 * 面板。外环用 box-shadow 而不是 border：切换状态时不会因为盒模型重排抖动 1px。
 *
 * `fill` 让卡片在定高网格里撑满，内容区自带滚动：一屏布局靠它而不是靠页面的
 * 长滚动。
 *
 * @param {{ title?: React.ReactNode, hint?: React.ReactNode, actions?: React.ReactNode,
 *           children: React.ReactNode, className?: string, bodyClassName?: string,
 *           padded?: boolean, fill?: boolean }} props
 */
export function Card({
  title,
  hint,
  actions,
  children,
  className = "",
  bodyClassName = "",
  padded = true,
  fill = false,
  ...rest
}) {
  return (
    <section className={`lens-panel ${fill ? "flex min-h-0 flex-col" : ""} ${className}`} {...rest}>
      {title || actions ? (
        <header className="flex shrink-0 items-center justify-between gap-3 px-3 pb-1.5 pt-2.5">
          <div className="flex min-w-0 items-baseline gap-2">
            <h2 className="truncate text-micro font-medium uppercase tracking-wider text-ink-muted">
              {title}
            </h2>
            {hint ? <span className="truncate text-micro text-ink-muted/70">{hint}</span> : null}
          </div>
          {actions ? <div className="flex shrink-0 items-center gap-1.5">{actions}</div> : null}
        </header>
      ) : null}
      <div
        className={`${fill ? "min-h-0 flex-1" : ""} ${padded ? "px-3 pb-3" : ""} ${bodyClassName}`}
      >
        {children}
      </div>
    </section>
  );
}

/**
 * 页面标题区。标题与副信息压在同一行，右侧放控件。
 *
 * 一屏布局里它只占 40px 左右，所以说明文字退到第二行的小字。
 *
 * @param {{ title: string, hint?: React.ReactNode, actions?: React.ReactNode }} props
 */
export function PageHeader({ title, hint, actions }) {
  return (
    <header className="flex shrink-0 flex-wrap items-center justify-between gap-x-4 gap-y-2">
      <div className="flex min-w-0 items-baseline gap-3">
        <h1 className="text-title font-semibold tracking-tight text-ink">{title}</h1>
        {hint ? <p className="truncate text-micro text-ink-muted">{hint}</p> : null}
      </div>
      {actions ? <div className="flex flex-wrap items-center gap-1.5">{actions}</div> : null}
    </header>
  );
}
