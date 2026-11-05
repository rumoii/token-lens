import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { AlertCircle, ArrowDown, ArrowRight, ArrowUp, RefreshCw } from "lucide-react";
import { api } from "../../lib/v1";
import { useTween } from "../../lib/use-tween";
import {
  bucketKeys,
  currentPeriod,
  periodAxis,
  periodCompare,
  periodElapsedDays,
  periodLabel,
  periodQuery,
  periodRange,
  rememberPeriod
} from "../../lib/period.js";
import { toolOf } from "../../lib/tools.js";
import { sortByToolOrder } from "../../lib/tool-colors";
import { detailSearch, nextDim, readDetail } from "../../lib/detail-query.js";
import { ToolTile } from "../../ui/lens/ToolTile.jsx";
import { SkeletonLines } from "../../ui/lens/EmptyState.jsx";
import { Button } from "../../ui/lens/Button.jsx";
import { isSuccessfulRun, syncState } from "../../lib/sync-state.js";
import { ApiError } from "../../lib/v1";
import { AsyncBlock, Money, useFormatTokens, useResource, useToolColors, useSyncState } from "./shared.jsx";
import { TrendChart, buildBuckets, nowBucketKey } from "./TrendChart.jsx";
import { PeriodControl, ViewSwitch } from "./PeriodControl.jsx";
import { DetailView } from "./DetailView.jsx";
import { Card, GoLink, Nt, SecHead, TweenNt, exact, useNarrow } from "./HomeParts.jsx";

/* ---------- 数字与文案的小工具 ---------- */

/** 大数字要拆成「数 + 单位」两段字号渲染。 */
function splitNumber(text) {
  const matched = /^(-?[\d,.]+)(万亿|亿|万|[KMBT])?$/.exec(text);
  return matched ? [matched[1], matched[2] || ""] : [text, ""];
}

// 卡片依次入场：序号 × --lens-stagger-enter（57ms，0.7× 折算后）
const enterAt = (n) => ({ animationDelay: `${n * 57}ms` });

/** 会滚动的大数字：拆成「数 + 单位」两段字号渲染。 */
function TweenBig({ value }) {
  const formatTokens = useFormatTokens();
  const shown = useTween(value);
  const [bigValue, bigUnit] = splitNumber(formatTokens(shown));
  return (
    <>
      {bigValue}
      <span className="ml-px text-[0.6em] font-medium tracking-normal">{bigUnit}</span>
    </>
  );
}

/** 会滚动的整数（会话数、活跃天数）。 */
function TweenInt({ value }) {
  const shown = useTween(value);
  return Math.round(shown);
}

/** 会滚动的金额。值为 null 时不滚，照原样显示。 */
function TweenMoney({ value, ...rest }) {
  const shown = useTween(value ?? 0);
  return <Money value={value === null ? null : shown} {...rest} />;
}

function deltaOf(current, previous) {
  if (!previous) return null;
  return Math.round(((current - previous) / previous) * 100);
}

const ymd = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

const sumTokens = (points) => (points ?? []).reduce((s, p) => s + (p.gross_tokens || 0), 0);

function DeltaPill({ value }) {
  const Icon = value >= 0 ? ArrowUp : ArrowDown;
  return (
    <span
      className={`inline-flex items-center gap-0.5 rounded-pill px-[7px] py-px text-[12.5px] font-medium ${
        value >= 0 ? "bg-clay-wash text-clay-ink" : "text-signal-ok"
      }`}
      style={
        value >= 0
          ? undefined
          : { background: "color-mix(in srgb, var(--lens-ok) 12%, transparent)" }
      }
    >
      <Icon className="h-3 w-3" aria-hidden />
      {Math.abs(value)}%
    </span>
  );
}

/* ---------- 热力图 ---------- */

function HeatCard({ yearMap, yearActive, yearStreak, narrow, recap }) {
  const formatTokens = useFormatTokens();
  // 当前指着的格子（在 days 里的序号）。悬停记下，再点一下取消，触屏也能用
  const [hot, setHot] = useState(null);
  const today = new Date();
  const start = new Date(today);
  if (narrow) start.setDate(today.getDate() - (today.getDay() + 133));
  else start.setDate(today.getDate() - 364);

  const days = [];
  for (const d = new Date(start); d <= today; d.setDate(d.getDate() + 1)) {
    days.push(new Date(d));
  }
  const blanks = start.getDay();
  const weeks = Math.ceil((blanks + days.length) / 7);

  const levelColor = (tokens) => {
    if (!tokens) return "var(--lens-heat-0)";
    if (tokens < 15e6) return "var(--lens-heat-1)";
    if (tokens < 30e6) return "var(--lens-heat-2)";
    if (tokens < 50e6) return "var(--lens-heat-3)";
    return "var(--lens-heat-4)";
  };

  const monthLabels = Array.from({ length: weeks }, (_, w) => {
    const d = new Date(start);
    d.setDate(d.getDate() - blanks + w * 7);
    return d.getDate() <= 7 ? `${d.getMonth() + 1}月` : "";
  });

  // 悬停格子的提示：跟着格子定位，靠左右两边的格子往里对齐，不出卡片
  const tip = (() => {
    if (hot === null) return null;
    const d = days[hot];
    const tokens = yearMap.get(ymd(d)) || 0;
    const col = Math.floor((blanks + hot) / 7);
    const row = (blanks + hot) % 7;
    const [left, shift] =
      col < 4
        ? [col / weeks, "translate(0, calc(-100% - 8px))"]
        : col > weeks - 5
          ? [(col + 1) / weeks, "translate(-100%, calc(-100% - 8px))"]
          : [(col + 0.5) / weeks, "translate(-50%, calc(-100% - 8px))"];
    return (
      <div
        className="pointer-events-none absolute z-10 whitespace-nowrap rounded-[8px] bg-surface-3 px-2.5 py-1.5 text-[12px] shadow-pop"
        style={{ left: `${left * 100}%`, top: `${(row / 7) * 100}%`, transform: shift }}
      >
        <div>
          {d.getMonth() + 1}月{d.getDate()}日 周{"日一二三四五六"[d.getDay()]}
        </div>
        <div className="text-ink-secondary tabular-nums">
          {tokens ? `${formatTokens(tokens)} token` : "没有用量"}
        </div>
      </div>
    );
  })();

  return (
    <Card className="lens-enter" style={enterAt(7)}>
      <SecHead title={narrow ? "最近 20 周" : "这一年"} sub="每个格子是一天，颜色越深用得越多" />
      <div className="px-[18px] pb-[18px] pt-3.5">
        <div
          className="mb-1.5 grid text-[11px] text-ink-faint"
          style={{ gridTemplateColumns: `repeat(${weeks}, 1fr)` }}
        >
          {monthLabels.map((m, i) => (
            <span key={i} className="overflow-visible whitespace-nowrap">
              {m}
            </span>
          ))}
        </div>
        <div
          className="relative grid gap-[3px]"
          style={{
            gridAutoFlow: "column",
            gridTemplateRows: "repeat(7, 1fr)",
            gridTemplateColumns: `repeat(${weeks}, 1fr)`
          }}
        >
          {Array.from({ length: blanks }, (_, i) => (
            <i key={`blank-${i}`} className="aspect-square w-full rounded-[3px] bg-transparent" />
          ))}
          {days.map((d, i) => {
            const tokens = yearMap.get(ymd(d)) || 0;
            return (
              <i
                key={ymd(d)}
                className={`lens-fade aspect-square w-full rounded-[3px] transition-[transform,box-shadow] duration-[170ms] ${
                  hot === i
                    ? "relative z-[2] scale-[1.15] shadow-[0_0_0_1.5px_var(--lens-surface-2),_0_0_0_3px_var(--lens-text-secondary)]"
                    : ""
                }`}
                style={{
                  background: levelColor(tokens),
                  animationDelay: `${230 + Math.floor((blanks + i) / 7) * 17}ms`
                }}
                onMouseEnter={() => setHot(i)}
                onMouseLeave={() => setHot(null)}
                onClick={() => setHot((c) => (c === i ? null : i))}
              />
            );
          })}
          {tip}
        </div>
        <div className="mt-2.5 flex flex-wrap items-center justify-between gap-2.5 text-caption text-ink-muted">
          {recap.newcomer ? (
            <span>
              从 {recap.firstText}开始记录，已经活跃 <b className="tabular-nums text-ink">{yearActive}</b> 天
            </span>
          ) : (
            <span>
              过去一年活跃 <b className="tabular-nums text-ink">{yearActive}</b> 天，最长连续 {yearStreak} 天
            </span>
          )}
          <span className="inline-flex items-center gap-[3px]">
            少
            {[0, 1, 2, 3, 4].map((l) => (
              <i
                key={l}
                className="h-[11px] w-[11px] rounded-[3px]"
                style={{ background: `var(--lens-heat-${l})` }}
              />
            ))}
            多
          </span>
        </div>
        {recap.total > 0 ? <YearRecap recap={recap} yearActive={yearActive} yearStreak={yearStreak} /> : null}
      </div>
    </Card>
  );
}

/** 热力图下面的年度小结：一共多少、最忙的一天、最长连续、用得最多的工具。 */
function YearRecap({ recap, yearActive, yearStreak }) {
  const formatTokens = useFormatTokens();
  const cell = "min-w-0 px-3.5 py-3";
  const busy = recap.busiest ? new Date(`${recap.busiest.key}T00:00:00`) : null;
  return (
    <div className="mt-4 grid grid-cols-2 rounded-xl bg-[var(--lens-fill-hover)] md:grid-cols-4 md:[&>div+div]:shadow-[inset_1px_0_0_var(--lens-line-soft)] max-md:[&>div:nth-child(even)]:shadow-[inset_1px_0_0_var(--lens-line-soft)] max-md:[&>div:nth-child(n+3)]:border-t max-md:[&>div:nth-child(n+3)]:border-[var(--lens-line-soft)]">
      <div className={cell}>
        <div className="text-caption text-ink-muted">{recap.newcomer ? "到现在一共" : "这一年一共"}</div>
        <div className="mt-0.5 text-[16px] font-semibold tabular-nums text-ink">
          <Nt value={recap.total} />
        </div>
        <div className="text-caption text-ink-muted">
          约值 <Money value={recap.cost} digits={0} mono={false} />
        </div>
      </div>
      <div className={cell}>
        <div className="text-caption text-ink-muted">最忙的一天</div>
        <div className="mt-0.5 text-[16px] font-semibold tabular-nums text-ink">
          {busy ? `${busy.getMonth() + 1}月${busy.getDate()}日` : "—"}
        </div>
        <div className="text-caption text-ink-muted">
          {recap.busiest ? `${formatTokens(recap.busiest.tokens)} token` : ""}
        </div>
      </div>
      <div className={cell}>
        <div className="text-caption text-ink-muted">最长连续</div>
        <div className="mt-0.5 text-[16px] font-semibold tabular-nums text-ink">{yearStreak} 天</div>
        <div className="text-caption text-ink-muted">
          {recap.newcomer && yearStreak === yearActive ? "从第一天起没断过" : `一共活跃 ${yearActive} 天`}
        </div>
      </div>
      <div className={cell}>
        <div className="text-caption text-ink-muted">用得最多</div>
        {recap.top ? (
          <>
            <div className="mt-0.5 flex min-w-0 items-center gap-1.5 text-[16px] font-semibold text-ink">
              <ToolTile id={recap.top.id} size={16} />
              <span className="truncate">{toolOf(recap.top.id).name}</span>
            </div>
            <div className="text-caption text-ink-muted">占 {Math.round(recap.top.share * 100)}%</div>
          </>
        ) : (
          <div className="mt-0.5 text-[16px] font-semibold text-ink">—</div>
        )}
      </div>
    </div>
  );
}

/* ---------- 首页 ---------- */

/**
 * 把「工具 × 模型」的分组拆成首页要的几样：工具排行、每个工具的模型数、常用模型。
 * 都从同一份数据来，所以各处的合计必然一致。
 */
function digestPairs(groups) {
  const bySource = new Map();
  const byModel = new Map();
  for (const g of groups ?? []) {
    if (!g.source || !(g.gross_tokens > 0)) continue;
    const tool = bySource.get(g.source) || { key: g.source, gross_tokens: 0, cost: 0, priced: false, models: 0 };
    tool.gross_tokens += g.gross_tokens;
    tool.models += 1;
    if (g.cost_usd !== null && g.cost_usd !== undefined) {
      tool.cost += Number(g.cost_usd);
      tool.priced = true;
    }
    bySource.set(g.source, tool);

    const name = g.model || "未知模型";
    const model = byModel.get(name) || { name, tokens: 0, byTool: new Map() };
    model.tokens += g.gross_tokens;
    model.byTool.set(g.source, (model.byTool.get(g.source) || 0) + g.gross_tokens);
    byModel.set(name, model);
  }
  const rank = [...bySource.values()]
    .map((t) => ({ ...t, cost_usd: t.priced ? t.cost : null }))
    .sort((a, b) => b.gross_tokens - a.gross_tokens);
  const models = [...byModel.values()].sort((a, b) => b.tokens - a.tokens).slice(0, 5);
  return { rank, models };
}

/**
 * 首页：同一个地址下的两个视图。`?view=detail` 是明细，其余是概览；周期两边共用。
 */
export function HomePage() {
  const { search } = useLocation();
  const navigate = useNavigate();
  const detail = readDetail(search);
  const period = currentPeriod(search);

  // 换周期时，明细保留工具 / 模型 / 项目筛选，去掉只属于旧周期的那个时段
  const goPeriod = (next) => {
    const text = rememberPeriod(next);
    navigate({ search: `?${detail.view === "detail" ? detailSearch(text, { ...detail, bucket: "" }) : text}` });
  };
  const goView = (view) => {
    const text = periodQuery(period);
    navigate({ search: `?${view === "detail" ? detailSearch(text) : text}` });
  };

  const controls = (
    <div className="flex flex-wrap items-center gap-2.5">
      <ViewSwitch view={detail.view} onChange={goView} />
      <PeriodControl period={period} range={periodRange(period)} onChange={goPeriod} />
    </div>
  );

  return detail.view === "detail" ? (
    <DetailView period={period} detail={detail} controls={controls} />
  ) : (
    <Overview period={period} controls={controls} onPeriod={goPeriod} />
  );
}

function overviewRequests(period) {
  const range = periodRange(period);
  const compare = periodCompare(period);
  const curParams = { from: range.from, to: range.to };
  const prevParams = compare ? { from: compare.from, to: compare.to } : null;
  const summary = () => api.summary(curParams);
  const previous = !prevParams ? [] : period.period === "today"
    ? [() => api.timeseries("hour", prevParams)]
    : [() => api.summary(prevParams), () => api.timeseries("day", prevParams)];
  const days = () => api.timeseries("day", curParams);
  const pairs = () => api.breakdown("source_model", curParams);
  const matrix = async (firstSeen) => {
    const axis = periodAxis(period, new Date(), firstSeen);
    const data = await api.matrix(axis.granularity, "source", curParams);
    return { axis, data };
  };
  const trend = async () => {
    // 「全部」的坐标轴取决于最早一条记录；同一刻的 summary 请求会被客户端合并
    const firstSeen = period.period === "all" ? (await summary()).activity?.first_seen ?? null : null;
    return matrix(firstSeen);
  };
  const prev = async () => {
    if (!prevParams) return null;
    if (period.period === "today") return { hours: await previous[0]() };
    const [prevSummary, prevDays] = await Promise.all(previous.map((load) => load()));
    return { summary: prevSummary, days: prevDays };
  };
  return {
    range,
    compare,
    summary,
    prev,
    days,
    pairs,
    trend,
    prefetch: [summary, ...previous, days, pairs, () => matrix(null), () => api.breakdown("source", curParams)]
  };
}

function Overview({ period, controls, onPeriod }) {
  const navigate = useNavigate();
  const narrow = useNarrow();
  const sync = useSyncState();
  const retrying = sync.phase === "running" || sync.phase === "conflict";
  // 指着某个工具（行或图例）时，图里其余工具变淡
  const [hiTool, setHiTool] = useState(null);
  const { order: toolSeq, colorOf } = useToolColors();

  const requests = overviewRequests(period);
  const { range, compare } = requests;
  // 依赖周期的数据都以这个 key 取；只有全部按同一个 key 回来，才换到新周期
  const pk = `${period.period}|${range.from}|${range.to}`;

  const summary = useResource(requests.summary, [pk]);
  const prev = useResource(requests.prev, [pk]);
  const days = useResource(requests.days, [pk]);
  const pairs = useResource(requests.pairs, [pk]);
  const trend = useResource(requests.trend, [pk]);

  const pricing = useResource(() => api.pricing(), []);
  const year = useResource(() => {
    const to = new Date();
    const from = new Date(to);
    from.setDate(to.getDate() - 364);
    return api.timeseries("day", { from: ymd(from), to: ymd(to) });
  }, []);
  const yearTools = useResource(() => {
    const to = new Date();
    const from = new Date(to);
    from.setDate(to.getDate() - 364);
    return api.breakdown("source", { from: ymd(from), to: ymd(to) });
  }, []);
  const recent = useResource(() => api.sessions({ limit: 5 }), []);
  const sourcesRes = useResource(() => api.sources(), []);

  const periodResources = [summary, prev, days, pairs, trend];
  const periodReady = periodResources.every((res) => res.fresh && !res.refreshing);

  const schedulePrefetchRef = useRef(null);
  const lastRevisitPrefetchRef = useRef(-Infinity);

  useEffect(() => {
    if (!periodReady) return undefined;
    let cancelled = false;
    const prefetchVersion = sync.version;
    const obsolete = () => cancelled || syncState.getSnapshot().version !== prefetchVersion;
    let running = false;
    let handle = null;
    const run = async () => {
      handle = null;
      if (obsolete()) return;
      running = true;
      try {
        for (const name of ["today", "week", "month"]) {
          if (name === period.period) continue;
          for (const load of overviewRequests({ period: name }).prefetch) {
            if (obsolete()) return;
            try {
              await load();
            } catch (_err) {
              // 预热失败不影响页面，继续预热后续请求
            }
          }
        }
      } finally {
        running = false;
      }
    };
    const schedule = () => {
      if (cancelled || running || handle !== null) return;
      const idle = typeof window.requestIdleCallback === "function";
      handle = idle ? window.requestIdleCallback(run) : window.setTimeout(run, 0);
    };
    schedulePrefetchRef.current = schedule;
    schedule();
    return () => {
      cancelled = true;
      schedulePrefetchRef.current = null;
      if (handle === null) return;
      if (typeof window.requestIdleCallback === "function") window.cancelIdleCallback?.(handle);
      else window.clearTimeout(handle);
    };
  }, [pk, period.period, periodReady, sync.version]);

  useEffect(() => {
    const onRevisit = () => {
      if (document.visibilityState !== "visible") return;
      const schedule = schedulePrefetchRef.current;
      if (!schedule) return;
      const now = Date.now();
      if (now - lastRevisitPrefetchRef.current < 60000) return;
      lastRevisitPrefetchRef.current = now;
      schedule();
    };
    window.addEventListener("focus", onRevisit);
    document.addEventListener("visibilitychange", onRevisit);
    return () => {
      window.removeEventListener("focus", onRevisit);
      document.removeEventListener("visibilitychange", onRevisit);
    };
  }, []);

  const reloadAll = useCallback(() => {
    for (const res of [summary, prev, days, pairs, trend, pricing, year, yearTools, recent, sourcesRes]) res.reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [summary.reload, prev.reload, days.reload, pairs.reload, trend.reload, pricing.reload,
    year.reload, yearTools.reload, recent.reload, sourcesRes.reload]);

  // 新周期的数据全部到齐才整体替换；在那之前继续显示上一个周期的完整画面
  const snapRef = useRef(null);
  if (periodResources.every((res) => res.fresh)) {
    snapRef.current = {
      pk,
      version: sync.version,
      period,
      compare,
      summary: summary.data,
      prev: prev.data,
      days: days.data,
      pairs: pairs.data,
      trend: trend.data
    };
  }
  const snap = snapRef.current;
  const failed = periodResources.find((res) => res.status === "error") ?? null;
  const switching = Boolean(snap && (snap.pk !== pk || snap.version !== sync.version));

  const handleRetry = async () => {
    if (retrying) return;
    try {
      if (sync.errorKind === "status") await syncState.retryStatus();
      else await syncState.startSync();
    } catch (_err) {
      // 共享同步状态保留本次请求错误。
    }
  };


  /* ---------- 静态数据（不随周期变） ---------- */
  const yearMap = useMemo(() => {
    const map = new Map();
    for (const point of year.data?.points ?? []) map.set(point.bucket.slice(0, 10), point.gross_tokens);
    return map;
  }, [year.data]);

  // 连续 365 天的日期序列：活跃天数与最长连续天不能拿稀疏 bucket 直接算
  const yearKeys = useMemo(() => {
    const keys = [];
    const today = new Date();
    for (let i = 364; i >= 0; i--) {
      const d = new Date(today);
      d.setDate(today.getDate() - i);
      keys.push(ymd(d));
    }
    return keys;
  }, []);
  const yearActive = yearKeys.filter((key) => (yearMap.get(key) || 0) > 0).length;
  const yearStreak = (() => {
    let best = 0;
    let run = 0;
    for (const key of yearKeys) {
      if ((yearMap.get(key) || 0) > 0) {
        run += 1;
        best = Math.max(best, run);
      } else {
        run = 0;
      }
    }
    return best;
  })();

  const lastRun = sourcesRes.data?.last_run ?? null;
  const syncWarning = sync.warning || (isSuccessfulRun(lastRun) ? lastRun.anomalies?.join("；") : null);
  const banner =
    sync.error || syncWarning || (sourcesRes.data && lastRun && !isSuccessfulRun(lastRun) && lastRun.status !== "running") ? (
      <div className="flex items-center gap-2.5 rounded-xl bg-surface-2 px-3.5 py-2.5 text-[13.5px] shadow-card">
        <AlertCircle className="h-4 w-4 shrink-0 text-signal-danger" aria-hidden />
        <span className="min-w-0 flex-1">
          <b>{sync.error?.message || (syncWarning ? `同步完成，有异常警告：${syncWarning}` : "上次同步没有完成。")}</b>
          {!syncWarning && lastRun?.anomalies?.[0] ? (
            <span className="text-ink-secondary"> {lastRun.anomalies[0]}</span>
          ) : null}
        </span>
        {!syncWarning || sync.error ? <button
          type="button"
          onClick={handleRetry}
          className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-[var(--lens-fill-hover)] px-3 text-[13px] font-medium text-ink transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-active)]"
        >
          <RefreshCw className={`h-3.5 w-3.5 ${retrying ? "animate-spin" : ""}`} aria-hidden />
          重试
        </button> : null}
        <Link
          to="/sources"
          className="inline-flex items-center gap-1 rounded-md px-1.5 py-1 text-[13px] text-ink-secondary no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
        >
          查看详情
        </Link>
      </div>
    ) : null;

  /* ---------- 页头 ---------- */
  const hour = new Date().getHours();
  const greet = hour < 6 ? "夜深了" : hour < 11 ? "早上好" : hour < 13 ? "中午好" : hour < 18 ? "下午好" : "晚上好";

  const head = (summaryLine) => (
    <div className="mb-1 flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
      {/* 宽度不够 420px 时整句独占一行，周期切换换到下一行，而不是把句子挤成一条 */}
      <div className="min-w-0 flex-1 basis-[420px]">
        <h1 className="font-serif text-[26px] font-medium leading-[1.25] tracking-[-0.01em] text-ink md:text-[30px]">
          {greet}
        </h1>
        <p className="mt-1.5 max-w-[760px] text-[15px] leading-[1.7] text-ink-secondary">{summaryLine}</p>
      </div>
      {controls}
    </div>
  );

  // 页顶的切换进度：数据换周期时出现，内容保持上一个周期的完整画面
  const progress =
    switching || periodResources.some((res) => res.refreshing) ? (
      <div
        className="pointer-events-none sticky top-0 z-20 -mb-[2px] h-[2px] overflow-hidden rounded-pill"
        role="progressbar"
        aria-label="正在加载"
      >
        <i className="lens-progress block h-full w-1/3 rounded-pill bg-clay" />
      </div>
    ) : null;

  /* ---------- 首次加载 / 失败 ---------- */
  if (!snap) {
    // 与下面两种渲染保持同样的前三个位置，页头不会在数据到达时被卸载重建
    return (
      <>
        {null}
        {banner}
        {head(
          failed ? null : (
            <span className="inline-block h-4 w-[420px] max-w-full animate-pulse rounded-md bg-[var(--lens-fill-hover)] align-middle" />
          )
        )}
        <Card className="px-[18px] py-5">
          {failed ? (
            <PeriodError error={failed.error} onRetry={reloadAll} />
          ) : (
            <SkeletonLines rows={6} />
          )}
        </Card>
      </>
    );
  }

  /* ---------- 派生数据：全部出自同一个周期的快照 ---------- */
  const sp = snap.period;
  const label = periodLabel(sp.period);
  const totals = snap.summary.totals;
  const totalTokens = totals.gross_tokens ?? 0;
  const totalCost = totals.cost_usd ?? null;
  const empty = totals.record_count === 0;
  const { rank, models: mergedModels } = digestPairs(snap.pairs.groups);
  const top = rank[0] ?? null;
  const now = new Date();
  // 堆叠和图例按固定顺序（工具第一次出现的先后），排行仍按本期用量
  const stackKeys = sortByToolOrder(rank.map((g) => g.key), toolSeq);
  const rankBy = new Map(rank.map((g) => [g.key, g]));
  const pq = periodQuery(sp);
  const detailTo = (d) => `/dashboard?${detailSearch(pq, d)}`;

  let cmpDelta = null;
  let cmpLabel = snap.compare?.label ?? "";
  if (sp.period === "today" && snap.prev?.hours) {
    // 两边都只算能落进小时桶的用量，截到当前这个小时
    const cutoff = `${snap.compare.from}T${String(now.getHours()).padStart(2, "0")}:00:00`;
    const yesterdaySoFar = sumTokens(snap.prev.hours.points.filter((p) => p.bucket <= cutoff));
    const todaySoFar = (snap.trend.data.rows ?? []).reduce((s, r) => s + (r.gross_tokens || 0), 0);
    cmpDelta = deltaOf(todaySoFar, yesterdaySoFar);
    cmpLabel = "昨天同一时间";
  } else if (snap.prev?.summary) {
    cmpDelta = deltaOf(totalTokens, snap.prev.summary.totals.gross_tokens);
  }

  const dayPoints = snap.days.points ?? [];
  const activeDays = dayPoints.filter((p) => p.gross_tokens > 0).length;
  const elapsedDays = periodElapsedDays(sp, now, snap.summary.activity?.first_seen ?? null);
  // 日均与趋势图的平均线同口径：只算能落进某一天的用量
  const perDay = sumTokens(dayPoints) / Math.max(1, activeDays);
  const prevDayPoints = snap.prev?.days?.points ?? null;
  const prevPerDay = prevDayPoints
    ? sumTokens(prevDayPoints) / Math.max(1, prevDayPoints.filter((p) => p.gross_tokens > 0).length)
    : null;

  const sessions = snap.summary.activity?.sessions ?? 0;
  const prevSessions = snap.prev?.summary?.activity?.sessions ?? null;
  const cacheRatio = snap.summary.activity?.cache_hit_ratio ?? null;

  const saved = (() => {
    if (!pricing.data) return null;
    const priceOf = new Map((pricing.data.models ?? []).map((m) => [m.model, m.prices]));
    let sum = 0;
    for (const group of snap.pairs.groups ?? []) {
      const prices = priceOf.get(group.model);
      if (!prices || prices.input == null || prices.cache_read == null) continue;
      sum += ((group.cache_read_tokens ?? 0) * (prices.input - prices.cache_read)) / 1e6;
    }
    return sum;
  })();

  const axis = snap.trend.axis;
  const nowKey = nowBucketKey(axis.granularity, now);
  const buckets = buildBuckets(snap.trend.data.rows, axis, now);
  const unallocated = snap.trend.data.unallocated?.gross_tokens ?? 0;

  const topShare = top ? top.gross_tokens / Math.max(1, totalTokens) : 0;
  const second = rank[1] ?? null;
  const toolName = (id) => (
    <span className="whitespace-nowrap">
      <ToolTile id={id} size={16} /> <b className="text-ink">{toolOf(id).name}</b>
    </span>
  );
  // 总结句只讲结论：在涨还是在降、主要用哪两个工具。数字留给下面的大数字，只说一次
  const direction = (() => {
    if (cmpDelta === null) return null;
    const up = (text) => <span className="font-medium text-clay-ink">{text}</span>;
    const down = (text) => <span className="font-medium text-signal-ok">{text}</span>;
    if (cmpDelta >= 50) return <>比{cmpLabel}{up("用得多了不少")}</>;
    if (cmpDelta >= 10) return <>比{cmpLabel}{up("用得多")}</>;
    if (cmpDelta <= -50) return <>比{cmpLabel}{down("少了不少")}</>;
    if (cmpDelta <= -10) return <>比{cmpLabel}{down("用得少")}</>;
    return <>和{cmpLabel}差不多</>;
  })();
  const subject = sp.period === "custom" ? "这段时间" : label;
  const summaryLine = empty ? (
    `${label}还没有用量。换个时间范围看看，或者等工具产生新的日志后再同步。`
  ) : (
    <>
      {sp.period === "all" ? (
        `从 ${firstSeenDay(snap.summary.activity?.first_seen)}开始记录，`
      ) : direction ? (
        <>
          {subject}
          {direction}，
        </>
      ) : (
        subject
      )}
      {top ? (
        <>
          {topShare >= 0.5 ? "大部分花在" : "用得最多的是"} {toolName(top.key)}
          {topShare >= 0.5 ? " 上" : ""}
          {second ? <>，其次是 {toolName(second.key)}</> : null}
        </>
      ) : null}
      。
      {snap.compare && cmpDelta === null ? (
        <span className="text-ink-muted">{cmpLabel}还没有记录，没法比。</span>
      ) : null}
    </>
  );

  // 换周期不变暗：内容保持上一个周期的完整画面，加载提示只留顶部的 progress
  const dim = "";

  /* ---------- 空范围 ---------- */
  if (empty) {
    return (
      <>
        {progress}
        {failed ? <PeriodError error={failed.error} onRetry={reloadAll} /> : null}
        {banner}
        {head(summaryLine)}
        <Card className={`px-6 py-11 text-center ${dim}`}>
          <div className="flex justify-center">
            <Mark40 />
          </div>
          <h3 className="mt-3 font-serif text-[22px] font-medium text-ink">{label}还没有用量</h3>
          <p className="mx-auto mt-1 max-w-[420px] text-body text-ink-muted">
            Token Lens 只统计已经写进日志的用量。可以换个时间范围，或者在工具里用一会儿再回来。
          </p>
          <div className="mt-[18px] flex items-center justify-center gap-2">
            {[
              ["month", "看本月"],
              ["all", "看全部"]
            ].map(([value, text]) => (
              <button
                key={value}
                type="button"
                onClick={() => onPeriod({ period: value })}
                className="inline-flex h-[30px] items-center rounded-lg bg-[var(--lens-fill-hover)] px-3 text-[13px] font-medium text-ink transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-active)]"
              >
                {text}
              </button>
            ))}
          </div>
        </Card>
      </>
    );
  }

  /* ---------- 大数字 + 工具分布 ---------- */
  const maxTokens = top ? top.gross_tokens : 1;
  const shown = rank.slice(0, 5);
  const rest = rank.slice(5);
  const pct = (tokens) => {
    const share = tokens / Math.max(1, totalTokens);
    return `${(share * 100).toFixed(share < 0.1 ? 1 : 0)}%`;
  };

  const hero = (
    <Card
      className="lens-enter grid grid-cols-1 gap-5 px-[18px] pb-5 pt-[22px] lg:grid-cols-[300px_1fr] lg:gap-7"
      style={enterAt(0)}
    >
      <div>
        <div className="text-[13px] text-ink-muted">{label === "全部" ? "累计用量" : `${label}用量`}</div>
        <div
          className="mt-1.5 font-serif text-[44px] font-semibold leading-[1.05] tracking-[-0.02em] tabular-nums text-ink md:text-[52px]"
          title={exact(totalTokens)}
        >
          <TweenBig value={totalTokens} />
          <span className="ml-1.5 text-[22px] font-medium tracking-normal text-ink-secondary">token</span>
        </div>
        <div className="mt-2 text-[15px] text-ink-secondary">
          约值
          <b className="ml-1 font-serif text-[22px] font-semibold text-ink">
            <TweenMoney value={totalCost} mono={false} />
          </b>
        </div>
        {cmpDelta === null ? (
          <div className="mt-2.5 text-[12.5px] text-ink-muted">按公开标准价估算，不是账单</div>
        ) : (
          <div className="mt-3 flex items-center gap-2">
            <DeltaPill value={cmpDelta} />
            <span className="text-[12.5px] text-ink-muted">比{cmpLabel}</span>
          </div>
        )}
      </div>

      <div className="pt-1">
        <div
          className="lens-reveal-x flex h-3 gap-0.5 overflow-hidden rounded-pill bg-[var(--lens-fill-hover)]"
          role="img"
          aria-label="按工具分布"
          style={{ animationDelay: "230ms" }}
        >
          {stackKeys.map((key) => (
            <i
              key={key}
              className="block h-full transition-[width,opacity] duration-[690ms] ease-lens"
              style={{
                width: `${(rankBy.get(key).gross_tokens / Math.max(1, totalTokens)) * 100}%`,
                background: colorOf(key),
                opacity: hiTool && hiTool !== key ? 0.35 : 1
              }}
              title={`${toolOf(key).name} ${pct(rankBy.get(key).gross_tokens)}`}
            />
          ))}
        </div>
        <ul className="mt-3.5 list-none p-0">
          {shown.map((group, index) => (
            <li key={group.key}>
              <Link
                to={detailTo({ tool: group.key, dim: nextDim("tool") })}
                title={`看 ${toolOf(group.key).name} 的明细`}
                onMouseEnter={() => setHiTool(group.key)}
                onMouseLeave={() => setHiTool(null)}
                className="-mx-2 grid h-[42px] grid-cols-[28px_minmax(0,1fr)_64px_40px] items-center gap-3 rounded-[10px] px-2 no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] md:grid-cols-[28px_minmax(0,150px)_1fr_72px_46px_72px]"
              >
                <ToolTile id={group.key} size={28} />
                <span className="min-w-0">
                  <span className="block truncate text-body font-medium text-ink">{toolOf(group.key).name}</span>
                  <span className="block text-caption text-ink-muted">{group.models} 个模型</span>
                </span>
                <span className="hidden h-1.5 overflow-hidden rounded-pill bg-[var(--lens-fill-hover)] md:block">
                  <i
                    className="lens-grow-x block h-full rounded-pill transition-[width,opacity] duration-[690ms] ease-lens"
                    style={{
                      width: `${(group.gross_tokens / maxTokens) * 100}%`,
                      background: colorOf(group.key),
                      animationDelay: `${230 + index * 57}ms`
                    }}
                  />
                </span>
                <span className="text-right text-[13.5px] tabular-nums text-ink">
                  <TweenNt value={group.gross_tokens} />
                </span>
                <span className="text-right text-[12.5px] tabular-nums text-ink-muted">{pct(group.gross_tokens)}</span>
                <span className="hidden text-right text-[13px] tabular-nums text-ink-secondary md:block">
                  {group.cost_usd === null ? (
                    <span className="text-ink-muted">未定价</span>
                  ) : (
                    <Money value={group.cost_usd} mono={false} />
                  )}
                </span>
              </Link>
            </li>
          ))}
        </ul>
        {rest.length ? (
          <div className="pt-1.5 text-[12.5px] text-ink-muted">
            另有 {rest.map((group) => toolOf(group.key).name).join("、")}，合计{" "}
            {pct(rest.reduce((sum, group) => sum + group.gross_tokens, 0))}
          </div>
        ) : null}
      </div>
    </Card>
  );

  /* ---------- 指标卡 ---------- */
  const spark = (values) => {
    if (!values || values.length < 2) return null;
    const mx = Math.max(...values, 1);
    const w = 76;
    const h = 28;
    const pts = values
      .map((v, i) => `${((i / (values.length - 1)) * w).toFixed(1)},${(h - (v / mx) * (h - 2) - 1).toFixed(1)}`)
      .join("L");
    return (
      <svg
        className="absolute right-4 top-[18px] h-7 w-[76px] overflow-visible"
        viewBox={`0 0 ${w} ${h}`}
        aria-hidden="true"
      >
        <path d={`M${pts}`} fill="none" stroke="var(--lens-clay)" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  };

  // 日均的小折线按连续的日子画，没用的日子是 0，不能跳过
  const elapsedKeys = (() => {
    const range0 = periodRange(sp, now);
    if (!range0.from) return dayPoints.map((p) => p.bucket);
    return bucketKeys("day", { from: range0.from, to: range0.to > ymd(now) ? ymd(now) : range0.to });
  })();
  const dayMap = new Map(dayPoints.map((p) => [p.bucket, p.gross_tokens]));
  const sparkValues = elapsedKeys.map((key) => dayMap.get(key) || 0);

  const weekDots =
    sp.period === "week"
      ? (() => {
          const monday = new Date(now);
          monday.setDate(now.getDate() - ((now.getDay() + 6) % 7));
          return (
            <div className="mt-0.5 flex gap-1">
              {Array.from({ length: 7 }, (_, i) => {
                const d = new Date(monday);
                d.setDate(monday.getDate() + i);
                const key = ymd(d);
                const future = key > ymd(now);
                const used = (dayMap.get(key) || 0) > 0;
                return (
                  <i
                    key={key}
                    className={`h-3.5 w-3.5 rounded ${
                      future
                        ? "shadow-[inset_0_0_0_1px_var(--lens-line-strong)]"
                        : used
                          ? "bg-clay"
                          : "bg-[var(--lens-fill-active)]"
                    }`}
                    title={`${d.getMonth() + 1}/${d.getDate()}${future ? " · 还没到" : used ? "" : " · 没有用量"}`}
                  />
                );
              })}
            </div>
          );
        })()
      : null;

  const kpiNumber = "font-serif text-[22px] font-semibold leading-[1.2] tracking-[-0.01em] tabular-nums text-ink lg:text-[26px]";

  // 今天只有一天：日均就是总量、活跃天数永远 1 / 1。换成按小时看的两张卡
  const todayCards = (() => {
    if (sp.period !== "today" || axis.granularity !== "hour") return null;
    const live = buckets.filter((b) => !b.future);
    const busy = live.reduce((best, b) => (b.total > (best?.total ?? 0) ? b : best), null);
    const hourOf = (key) => Number(String(key).slice(11, 13));
    const current = buckets.find((b) => b.bucket === nowKey)?.total ?? 0;
    const hh = String(now.getHours()).padStart(2, "0");
    const yesterdayHour = snap.prev?.hours?.points?.find((p) => p.bucket === `${snap.compare.from}T${hh}:00:00`);
    // 这一小时只过了一部分，昨天那一小时按同样的比例截
    const yesterdaySoFar = yesterdayHour ? (yesterdayHour.gross_tokens * now.getMinutes()) / 60 : null;
    const hourDelta = yesterdaySoFar ? deltaOf(current, yesterdaySoFar) : null;
    return {
      busy: (
        <Card className="lens-enter flex flex-col gap-1 px-[18px] pb-[14px] pt-4" style={enterAt(1)}>
          <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">最忙的一小时</div>
          {busy ? (
            <>
              <div className={kpiNumber}>
                {hourOf(busy.bucket)}:00
                <span className="font-sans text-[15px] font-normal text-ink-muted"> – {hourOf(busy.bucket) + 1}:00</span>
              </div>
              <div className="text-caption text-ink-muted">
                <Nt value={busy.total} /> token，占今天的 {Math.round((busy.total / Math.max(1, totalTokens)) * 100)}%
              </div>
            </>
          ) : (
            <div className={kpiNumber}>—</div>
          )}
        </Card>
      ),
      now: (
        <Card className="lens-enter flex flex-col gap-1 px-[18px] pb-[14px] pt-4" style={enterAt(2)}>
          <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">这一小时</div>
          <div className={kpiNumber}>
            <Nt value={current} />
          </div>
          <div className="flex flex-wrap items-center gap-1.5 text-caption text-ink-muted">
            {hourDelta !== null ? <DeltaPill value={hourDelta} /> : null}
            <span>
              {now.getHours()}:00 到现在{hourDelta !== null ? "，比昨天这时候" : ""}
            </span>
          </div>
        </Card>
      )
    };
  })();

  const kpis = (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4 lg:gap-4">
      {todayCards ? todayCards.busy : null}
      {todayCards ? todayCards.now : null}
      {todayCards ? null : (
      <Card className="lens-enter relative flex flex-col gap-1 px-[18px] pb-[14px] pt-4" style={enterAt(1)}>
        <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">日均用量</div>
        <div className={kpiNumber}>
          <TweenNt value={perDay} />
        </div>
        <div className="flex items-center gap-1.5 text-caption text-ink-muted">
          {prevPerDay && deltaOf(perDay, prevPerDay) !== null ? <DeltaPill value={deltaOf(perDay, prevPerDay)} /> : null}
          <span>按有用量的天算</span>
        </div>
        {spark(sparkValues)}
      </Card>
      )}

      <Card
        className="lens-enter flex flex-col gap-1 px-[18px] pb-[14px] pt-4"
        style={enterAt(todayCards ? 3 : 2)}
      >
        <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">会话</div>
        <div className={kpiNumber}>
          <TweenInt value={sessions} />
        </div>
        <div className="flex items-center gap-1.5 text-caption text-ink-muted">
          {prevSessions ? <DeltaPill value={deltaOf(sessions, prevSessions)} /> : null}
          <span>
            平均每个 <Nt value={totalTokens / Math.max(1, sessions)} />
          </span>
        </div>
      </Card>

      {todayCards ? null : (
      <Card className="lens-enter flex flex-col gap-1 px-[18px] pb-[14px] pt-4" style={enterAt(3)}>
        <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">活跃天数</div>
        <div className={kpiNumber}>
          <TweenInt value={activeDays} />
          <span className="font-sans text-[15px] font-normal text-ink-muted">
            {" "}
            / {elapsedDays} 天
          </span>
        </div>
        {weekDots || (
          <div className="flex items-center gap-1.5 text-caption text-ink-muted">最长连续 {yearStreak} 天</div>
        )}
      </Card>
      )}

      <Card className="lens-enter flex flex-col gap-1 px-[18px] pb-[14px] pt-4" style={enterAt(4)}>
        <div className="flex items-center gap-1.5 text-[13px] text-ink-muted">
          缓存帮你省了
          <span
            className="inline-flex h-[15px] w-[15px] cursor-help items-center justify-center rounded-full text-[10px] text-ink-muted"
            style={{ boxShadow: "inset 0 0 0 1px var(--lens-line-strong)" }}
            title="工具重复发送的上下文命中缓存时，按缓存价而不是输入价计费。这里是两者的差额，按公开价估算。"
          >
            ?
          </span>
        </div>
        <AsyncBlock refreshing={pricing.refreshing} status={pricing.status} error={pricing.error} onRetry={pricing.reload} rows={1}>
          <div className={kpiNumber}>{saved === null ? "—" : <TweenMoney value={saved} digits={0} mono={false} />}</div>
          <div className="flex items-center gap-1.5 text-caption text-ink-muted">
            {cacheRatio === null ? <span>—</span> : <span>{Math.round(cacheRatio * 100)}% 的输入走了缓存</span>}
          </div>
        </AsyncBlock>
      </Card>
    </div>
  );

  /* ---------- 趋势 + 常用模型 ---------- */
  const unitWord = { hour: "每小时", day: "每天", month: "每月" }[axis.granularity];
  const trendAndModels = (
    <div className="grid grid-cols-1 gap-3 lg:grid-cols-[2fr_1fr] lg:gap-4">
      <Card className="lens-enter" style={enterAt(5)}>
        <SecHead
          title="趋势"
          sub={`${unitWord}用了多少，颜色代表工具，虚线是平均值${
            axis.granularity === "hour" ? "" : `。点柱子看那${unitWord.slice(1)}的明细`
          }`}
          action={<GoLink to={detailTo({})}>看明细</GoLink>}
        />
        <div className="px-[18px] pb-[18px] pt-3.5">
          <div className="flex flex-wrap gap-x-3.5 gap-y-1 text-caption text-ink-secondary">
            {stackKeys.slice(0, 8).map((key) => (
              <span
                key={key}
                className="inline-flex items-center gap-1.5"
                onMouseEnter={() => setHiTool(key)}
                onMouseLeave={() => setHiTool(null)}
              >
                <i className="h-[9px] w-[9px] rounded-[3px]" style={{ background: colorOf(key) }} />
                {toolOf(key).name}
              </span>
            ))}
          </div>
          <TrendChart
            buckets={buckets}
            order={stackKeys}
            colorOf={colorOf}
            onPick={
              axis.granularity === "hour"
                ? null
                : (bucket) => navigate(detailTo({ bucket, dim: nextDim("bucket") }))
            }
            granularity={axis.granularity}
            weekdays={sp.period === "week"}
            grow
            highlight={hiTool}
          />
          {unallocated > 0 ? (
            <p className="mt-2 text-[12.5px] text-ink-muted">
              另有 <Nt value={unallocated} /> token 来自跨{unitWord.slice(1)}的会话快照，没法按
              {unitWord.slice(1)}拆开，不在图里；上面的总量已经算上了。
            </p>
          ) : null}
        </div>
      </Card>

      <Card className="lens-enter" style={enterAt(6)}>
        <SecHead
          title="常用模型"
          sub={`${label === "全部" ? "累计" : label}用得最多的 5 个`}
          action={<GoLink to={detailTo({ dim: "model" })}>全部</GoLink>}
        />
        <div className="px-[18px] pb-[18px] pt-3.5">
          <ul className="flex list-none flex-col gap-1 p-0">
            {mergedModels.map((model, index) => {
              const topTool = [...model.byTool.entries()].sort((a, b) => b[1] - a[1])[0][0];
              // 没写模型名的记录没法按模型筛选，这一行就不做成链接
              const known = model.name !== "未知模型";
              const Row = known ? Link : "div";
              return (
                <li key={model.name}>
                  <Row
                    {...(known
                      ? { to: detailTo({ model: model.name, dim: nextDim("model") }), title: `看 ${model.name} 的明细` }
                      : {})}
                    className="-mx-2 block rounded-[9px] px-2 py-1.5 no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)]"
                  >
                  <div className="flex items-center gap-2 text-[13px]">
                    <ToolTile id={topTool} size={16} />
                    <span className="min-w-0 flex-1 truncate font-medium text-ink">{model.name}</span>
                    <span className="tabular-nums text-ink-secondary">
                      <Nt value={model.tokens} />
                    </span>
                    <span className="w-[38px] text-right tabular-nums text-ink-muted">
                      {Math.round((model.tokens / Math.max(1, totalTokens)) * 100)}%
                    </span>
                  </div>
                  <div className="mt-1.5 h-[5px] overflow-hidden rounded-pill bg-[var(--lens-fill-hover)]">
                    <i
                      className="lens-grow-x block h-full rounded-pill transition-[width,opacity] duration-[690ms] ease-lens"
                      style={{
                        width: `${(model.tokens / Math.max(1, mergedModels[0].tokens)) * 100}%`,
                        background: colorOf(topTool),
                        animationDelay: `${230 + index * 57}ms`
                      }}
                    />
                  </div>
                  </Row>
                </li>
              );
            })}
          </ul>
        </div>
      </Card>
    </div>
  );

  /* ---------- 这一年 + 最近会话 ---------- */
  const agoText = (iso) => {
    const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
    return minutes < 1
      ? "刚刚"
      : minutes < 60
        ? `${minutes} 分钟前`
        : minutes < 1440
          ? `${Math.round(minutes / 60)} 小时前`
          : `${Math.round(minutes / 1440)} 天前`;
  };
  const spanText = (startIso, endIso) => {
    const minutes = Math.max(0, Math.round((new Date(endIso) - new Date(startIso)) / 60000));
    return minutes < 60 ? `${minutes} 分钟` : `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
  };

  const recap = (() => {
    let busiest = null;
    let firstKey = null;
    for (const point of year.data?.points ?? []) {
      const key = point.bucket.slice(0, 10);
      if (point.gross_tokens > (busiest?.tokens ?? 0)) busiest = { key, tokens: point.gross_tokens };
      if (point.gross_tokens > 0 && (!firstKey || key < firstKey)) firstKey = key;
    }
    const yearTotals = yearTools.data?.totals;
    const topGroup = (yearTools.data?.groups ?? [])
      .filter((g) => g.key)
      .sort((a, b) => b.gross_tokens - a.gross_tokens)[0];
    const first = firstKey ? new Date(`${firstKey}T00:00:00`) : null;
    return {
      total: yearTotals?.gross_tokens ?? 0,
      cost: yearTotals?.cost_usd ?? null,
      busiest,
      top: topGroup && yearTotals?.gross_tokens ? { id: topGroup.key, share: topGroup.gross_tokens / yearTotals.gross_tokens } : null,
      // 不到一个月的新用户：热力图大半是空的，说清楚从哪天开始记录
      newcomer: yearActive < 30,
      firstText: first ? `${first.getMonth() + 1} 月 ${first.getDate()} 日` : ""
    };
  })();

  const heatAndSessions = (
    <div className="grid grid-cols-1 items-start gap-3 lg:grid-cols-[2fr_1fr] lg:gap-4">
      <AsyncBlock refreshing={year.refreshing} status={year.status} error={year.error} onRetry={year.reload}>
        <AsyncBlock refreshing={yearTools.refreshing} status={yearTools.status} error={yearTools.error} onRetry={yearTools.reload}>
        <HeatCard yearMap={yearMap} yearActive={yearActive} yearStreak={yearStreak} narrow={narrow} recap={recap} />
        </AsyncBlock>
      </AsyncBlock>

      <Card className="lens-enter" style={enterAt(8)}>
        <SecHead title="最近会话" sub="每次打开工具做的一件事" />
        <div className="px-[18px] pb-[18px] pt-2">
          <AsyncBlock refreshing={recent.refreshing} status={recent.status} error={recent.error} onRetry={recent.reload}>
            <ul className="list-none p-0">
              {(recent.data?.items ?? []).map((item) => {
                const project = item.project_key
                  ? item.project_key.split(/[\\/]/).filter(Boolean).pop()
                  : null;
                const target = `/sessions?${new URLSearchParams({ source: item.source, session: item.session_id })}`;
                return (
                  <li key={`${item.source}|${item.session_id}`}>
                    <Link
                      to={target}
                      className="-mx-2 flex items-center gap-2.5 rounded-[10px] px-2 py-[9px] no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)]"
                    >
                      <ToolTile id={item.source} size={28} />
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-[13.5px] font-medium text-ink">
                          {project || <span className="text-ink-muted">没有记录项目</span>}
                        </div>
                        <div className="text-caption text-ink-muted">
                          {toolOf(item.source).name} · {agoText(item.last_seen_at)} ·{" "}
                          {spanText(item.started_at, item.last_seen_at)}
                        </div>
                      </div>
                      <span className="text-[13px] tabular-nums text-ink">
                        <Nt value={item.gross_tokens} />
                      </span>
                    </Link>
                  </li>
                );
              })}
            </ul>
            <Link
              to="/sessions"
              className="mt-1.5 inline-flex items-center gap-1 rounded-md px-1.5 py-1 text-[12.5px] text-ink-muted no-underline transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
            >
              查看全部会话 <ArrowRight className="h-3 w-3" aria-hidden />
            </Link>
          </AsyncBlock>
        </div>
      </Card>
    </div>
  );

  return (
    <>
      {progress}
      {failed ? <PeriodError error={failed.error} onRetry={reloadAll} /> : null}
      {banner}
      {head(summaryLine)}
      <div className={`flex flex-col gap-3 md:gap-4 ${dim}`} aria-busy={switching || undefined}>
        {hero}
        {kpis}
        {trendAndModels}
      </div>
      {heatAndSessions}
      <p className="mt-1 text-xs text-ink-muted">
        金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。套餐用户的实际花费通常更低。
      </p>
    </>
  );
}

function PeriodError({ error, onRetry }) {
  const code = error instanceof ApiError ? error.code : "request_failed";
  return (
    <div className="flex items-start gap-2">
      <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-signal-danger" aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="text-caption font-medium text-ink">加载失败（{code}）</p>
        <p className="mt-0.5 break-words text-caption text-ink-muted">{error?.message || "请求失败"}</p>
      </div>
      <Button variant="ghost" size="xs" onClick={onRetry}>
        重试
      </Button>
    </div>
  );
}

function firstSeenDay(iso) {
  const d = new Date(iso || "");
  if (Number.isNaN(d.getTime())) return "最早一条记录";
  return `${d.getMonth() + 1} 月 ${d.getDate()} 日`;
}

function Mark40() {
  return (
    <svg width="40" height="40" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <circle cx="12" cy="12" r="8.5" stroke="var(--lens-line-strong)" strokeWidth="1.5" />
      <circle cx="12" cy="12" r="4.5" stroke="var(--lens-clay)" strokeWidth="1.5" />
      <circle cx="12" cy="12" r="1.4" fill="var(--lens-clay)" />
      <path
        d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3"
        stroke="var(--lens-line-strong)"
        strokeWidth="1.5"
        strokeLinecap="round"
      />
    </svg>
  );
}
