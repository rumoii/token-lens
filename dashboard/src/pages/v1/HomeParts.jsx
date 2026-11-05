import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowRight } from "lucide-react";
import { useFormatTokens } from "./shared.jsx";
import { useTween } from "../../lib/use-tween";

// 首页概览和明细共用的小零件。

export const exact = (v) => `${Math.round(v).toLocaleString("en-US")} token`;

/** 缩写值。缩写过的 token 数一律带精确值悬停。 */
export function Nt({ value }) {
  const formatTokens = useFormatTokens();
  return (
    <span className="tabular-nums" title={exact(value)}>
      {formatTokens(value)}
    </span>
  );
}

/** 会滚动的 token 数。title 给精确的目标值。 */
export function TweenNt({ value, delayMs }) {
  const formatTokens = useFormatTokens();
  const shown = useTween(value, delayMs === undefined ? undefined : { delayMs });
  return (
    <span className="tabular-nums" title={exact(value)}>
      {formatTokens(shown)}
    </span>
  );
}

export function useNarrow() {
  const query = "(max-width: 767px)";
  const [narrow, setNarrow] = useState(
    () =>
      typeof window !== "undefined" && typeof window.matchMedia === "function"
        ? window.matchMedia(query).matches
        : false
  );
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return undefined;
    const mq = window.matchMedia(query);
    const onChange = (event) => setNarrow(event.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);
  return narrow;
}

export function Card({ children, className = "", style }) {
  return (
    <section style={style} className={`rounded-[14px] bg-surface-2 shadow-card ${className}`}>
      {children}
    </section>
  );
}

export function SecHead({ title, sub, action = null }) {
  return (
    <div className="flex items-start justify-between gap-3 px-[18px] pt-4">
      <div>
        <h2 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">{title}</h2>
        {sub ? <p className="mt-0.5 text-[12.5px] text-ink-muted">{sub}</p> : null}
      </div>
      {action}
    </div>
  );
}

/** 卡片右上角去明细的小链接。 */
export function GoLink({ to, children }) {
  return (
    <Link
      to={to}
      className="-mx-1.5 -my-0.5 inline-flex shrink-0 items-center gap-1 whitespace-nowrap rounded-md px-1.5 py-0.5 text-[12.5px] text-ink-muted no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
    >
      {children} <ArrowRight className="h-3 w-3" aria-hidden />
    </Link>
  );
}
