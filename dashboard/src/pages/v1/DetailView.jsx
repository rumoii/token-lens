import React, { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ChevronDown, X } from "lucide-react";
import { api } from "../../lib/v1";
import { periodAxis, periodLabel, periodQuery, periodRange } from "../../lib/period.js";
import { toolOf } from "../../lib/tools.js";
import { sortByToolOrder } from "../../lib/tool-colors";
import { bucketRange, detailSearch, nextDim } from "../../lib/detail-query.js";
import { Segmented } from "../../ui/lens/Segmented.jsx";
import { ToolTile } from "../../ui/lens/ToolTile.jsx";
import { AsyncBlock, Money, useFormatTokens, useResource, useToolColors } from "./shared.jsx";
import { Card, Nt, SecHead, useNarrow } from "./HomeParts.jsx";
import { TrendChart, buildBuckets } from "./TrendChart.jsx";

const KINDS = [
  ["input_tokens", "新输入", "这次新发给模型的内容"],
  ["output_tokens", "输出", "模型写回来的内容"],
  ["cache_read_tokens", "读缓存", "重复发送、命中缓存的上下文，价格便宜很多"],
  ["cache_write_tokens", "写缓存", "第一次写进缓存的内容"]
];

const DIM_OPTIONS = [
  ["date", "按时间"],
  ["tool", "按工具"],
  ["model", "按模型"],
  ["project", "按项目"]
];

const projectName = (key) => (key ? key.split(/[\\/]/).filter(Boolean).pop() : null);

function bucketText(bucket) {
  if (/T\d{2}/.test(bucket)) return `${Number(bucket.slice(11, 13))}:00`;
  if (/^\d{4}-\d{2}$/.test(bucket)) return `${Number(bucket.slice(0, 4))}年${Number(bucket.slice(5, 7))}月`;
  const d = new Date(`${bucket}T00:00:00`);
  return `${d.getMonth() + 1}月${d.getDate()}日 周${"日一二三四五六"[d.getDay()]}`;
}

/** 「全部」的坐标轴取决于最早一条记录。 */
async function loadAxis(period, base) {
  const firstSeen = period.period === "all" ? (await api.summary(base)).activity?.first_seen ?? null : null;
  return periodAxis(period, new Date(), firstSeen);
}

/**
 * 筛选下拉。Esc 或点外面关闭，方向键在选项间移动。
 *
 * @param {{ label: string, options: Array<{ value: string, label: React.ReactNode, tokens: number }>,
 *           onPick: (value: string) => void }} props
 */
function FilterMenu({ label, options, onPick }) {
  const formatTokens = useFormatTokens();
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);
  const buttonRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onDown = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    wrapRef.current?.querySelector("[role=menuitem]")?.focus();
    return () => document.removeEventListener("mousedown", onDown);
  }, [open]);

  const onKeyDown = (event) => {
    if (event.key === "Escape") {
      setOpen(false);
      buttonRef.current?.focus();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const items = [...(wrapRef.current?.querySelectorAll("[role=menuitem]") ?? [])];
    const at = items.indexOf(document.activeElement);
    const next = (at + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
    items[next]?.focus();
  };

  return (
    <div ref={wrapRef} className="relative" onKeyDown={onKeyDown}>
      <button
        ref={buttonRef}
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        disabled={options.length === 0}
        onClick={() => setOpen((v) => !v)}
        className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-surface-2 pl-3 pr-2.5 text-[13px] text-ink-secondary shadow-thumb transition-colors duration-fast ease-lens hover:text-ink disabled:opacity-50"
      >
        {label}
        <ChevronDown className="h-3 w-3 text-ink-muted" aria-hidden />
      </button>
      {open ? (
        <div
          role="menu"
          className="absolute left-0 top-9 z-30 max-h-[300px] min-w-[220px] overflow-y-auto rounded-xl bg-surface-3 p-1.5 shadow-pop"
        >
          {options.map((option) => (
            <button
              key={option.value}
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onPick(option.value);
              }}
              className="flex h-[34px] w-full items-center gap-2 rounded-lg px-2 text-left text-[13px] text-ink outline-none hover:bg-[var(--lens-fill-hover)] focus-visible:bg-[var(--lens-fill-hover)]"
            >
              <span className="flex min-w-0 flex-1 items-center gap-2 truncate">{option.label}</span>
              <span className="text-caption tabular-nums text-ink-muted">{formatTokens(option.tokens)}</span>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function Tag({ label, children, onRemove }) {
  return (
    <span className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-clay-wash pl-2.5 pr-1.5 text-[13px] font-medium text-clay-ink">
      <span className="font-normal opacity-70">{label}</span>
      {children}
      <button
        type="button"
        onClick={onRemove}
        aria-label={`去掉${label}筛选`}
        className="inline-flex h-5 w-5 items-center justify-center rounded-md transition-colors duration-fast ease-lens hover:bg-[color-mix(in_srgb,var(--lens-clay)_18%,transparent)]"
      >
        <X className="h-3.5 w-3.5" aria-hidden />
      </button>
    </span>
  );
}

/**
 * 明细视图：首页的第二个视图（`/dashboard?view=detail`）。
 * 工具、模型、项目、时段四种筛选可以叠加，表格可以换四种拆法；首页各模块下钻到这里时带着筛选。
 *
 * @param {{ period: Object, detail: ReturnType<typeof import("../../lib/detail-query.js").readDetail>,
 *           controls: React.ReactNode }} props
 */
export function DetailView({ period, detail, controls }) {
  const formatTokens = useFormatTokens();
  const navigate = useNavigate();
  const narrow = useNarrow();
  const { order: toolSeq, colorOf } = useToolColors();
  const [sort, setSort] = useState({ key: null, dir: -1 });

  const range = periodRange(period);
  const base = { from: range.from, to: range.to };
  const filter = {
    ...(detail.tool ? { source: detail.tool } : {}),
    ...(detail.model ? { model: detail.model } : {}),
    ...(detail.project ? { project: detail.project } : {})
  };
  // 选了某个时段时，汇总和表格只看这一段；趋势仍画整个周期，其余柱子变淡
  const picked = detail.bucket ? bucketRange(detail.bucket, base) : null;
  const selectedBucket = picked || detail.bucket.includes("T") ? detail.bucket : "";
  const scoped = picked ? { ...base, ...picked, ...filter } : { ...base, ...filter };
  const pk = JSON.stringify([period, detail.tool, detail.model, detail.project]);
  const sk = JSON.stringify([pk, selectedBucket]);

  const options = useResource(
    () => Promise.all([api.breakdown("source_model", base), api.breakdown("project", base)]),
    [JSON.stringify(period)]
  );
  const summary = useResource(() => api.summary(scoped), [sk]);
  const trend = useResource(async () => {
    const axis = await loadAxis(period, base);
    return { axis, data: await api.matrix(axis.granularity, "source", { ...base, ...filter }) };
  }, [pk]);
  const table = useResource(async () => {
    if (detail.dim === "date") {
      const axis = await loadAxis(period, base);
      const granularity = picked ? "day" : axis.granularity;
      return { kind: "date", data: await api.timeseries(granularity, scoped) };
    }
    const by = { tool: "source", model: "source_model", project: "project" }[detail.dim];
    return { kind: detail.dim, data: await api.breakdown(by, scoped) };
  }, [sk, detail.dim]);

  const go = (next) => navigate(`/dashboard?${detailSearch(periodQuery(period), next)}`);
  const setFilter = (key, value) => go({ ...detail, [key]: value, dim: value ? nextDim(key) : detail.dim });
  const clearAll = () => go({ dim: detail.dim });

  /* ---------- 筛选选项 ---------- */
  const [pairs, projects] = options.data ?? [null, null];
  const toolOptions = [];
  const modelOptions = new Map();
  for (const g of pairs?.groups ?? []) {
    if (!(g.gross_tokens > 0)) continue;
    const tool = toolOptions.find((t) => t.value === g.source);
    if (tool) tool.tokens += g.gross_tokens;
    else toolOptions.push({ value: g.source, tokens: g.gross_tokens });
    if (g.model) {
      const m = modelOptions.get(g.model) || { value: g.model, tokens: 0, tool: g.source };
      m.tokens += g.gross_tokens;
      modelOptions.set(g.model, m);
    }
  }
  toolOptions.sort((a, b) => b.tokens - a.tokens);
  const menus = {
    tool: toolOptions.map((t) => ({
      value: t.value,
      tokens: t.tokens,
      label: (
        <>
          <ToolTile id={t.value} size={16} />
          {toolOf(t.value).name}
        </>
      )
    })),
    model: [...modelOptions.values()]
      .sort((a, b) => b.tokens - a.tokens)
      .map((m) => ({
        value: m.value,
        tokens: m.tokens,
        label: (
          <>
            <ToolTile id={m.tool} size={16} />
            <span className="truncate">{m.value}</span>
          </>
        )
      })),
    // 没写工作目录的记录没法按项目筛选，不进下拉
    project: (projects?.groups ?? [])
      .filter((g) => g.key && g.gross_tokens > 0)
      .sort((a, b) => b.gross_tokens - a.gross_tokens)
      .map((g) => ({ value: g.key, tokens: g.gross_tokens, label: <span className="truncate" title={g.key}>{projectName(g.key)}</span> }))
  };

  const tags = [];
  if (detail.tool)
    tags.push(
      <Tag key="tool" label="工具" onRemove={() => setFilter("tool", "")}>
        <ToolTile id={detail.tool} size={16} />
        {toolOf(detail.tool).name}
      </Tag>
    );
  if (detail.model)
    tags.push(
      <Tag key="model" label="模型" onRemove={() => setFilter("model", "")}>
        {detail.model}
      </Tag>
    );
  if (detail.project)
    tags.push(
      <Tag key="project" label="项目" onRemove={() => setFilter("project", "")}>
        <span title={detail.project}>{projectName(detail.project)}</span>
      </Tag>
    );
  if (selectedBucket)
    tags.push(
      <Tag key="bucket" label="时间" onRemove={() => setFilter("bucket", "")}>
        {bucketText(selectedBucket)}
      </Tag>
    );

  const filterBar = (
    <div className="flex flex-wrap items-center gap-2">
      <FilterMenu label="工具" options={menus.tool} onPick={(v) => setFilter("tool", v)} />
      <FilterMenu label="模型" options={menus.model} onPick={(v) => setFilter("model", v)} />
      <FilterMenu label="项目" options={menus.project} onPick={(v) => setFilter("project", v)} />
      {tags}
      {tags.length ? (
        <button
          type="button"
          onClick={clearAll}
          className="rounded-md px-1.5 py-1 text-[12.5px] text-ink-muted transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
        >
          清除筛选
        </button>
      ) : (
        <span className="ml-1 text-[12.5px] text-ink-muted">从首页点工具、模型或柱子进来，会自动带上筛选</span>
      )}
    </div>
  );

  /* ---------- 汇总 ---------- */
  const totals = summary.data?.totals;
  const activity = summary.data?.activity;
  const stat = (label, value, hint) => (
    <div className="min-w-0 px-[18px] py-3.5">
      <div className="flex items-center gap-1.5 text-[12.5px] text-ink-muted">{label}</div>
      <div className="mt-0.5 font-serif text-[22px] font-semibold tabular-nums text-ink">{value}</div>
      <div className="text-caption text-ink-muted">{hint}</div>
    </div>
  );
  const strip = (
    <Card className="grid grid-cols-2 md:grid-cols-4 md:[&>*+*]:shadow-[inset_1px_0_0_var(--lens-line-soft)] max-md:[&>*:nth-child(even)]:shadow-[inset_1px_0_0_var(--lens-line-soft)] max-md:[&>*:nth-child(n+3)]:border-t max-md:[&>*:nth-child(n+3)]:border-[var(--lens-line-soft)]">
      <AsyncBlock refreshing={summary.refreshing} status={summary.status} error={summary.error} onRetry={summary.reload} rows={2}>
        {stat("用量", <Nt value={totals?.gross_tokens ?? 0} />, "token")}
        {stat("约值", <Money value={totals?.cost_usd ?? null} mono={false} />, "按公开价估算")}
        {stat("会话", activity?.sessions ?? 0, "这段时间里有用量的")}
        {stat(
          <>
            缓存命中
            <span
              className="inline-flex h-[15px] w-[15px] cursor-help items-center justify-center rounded-full text-[10px]"
              style={{ boxShadow: "inset 0 0 0 1px var(--lens-line-strong)" }}
              title="读缓存 ÷（新输入 + 读缓存）。越高越省钱。"
            >
              ?
            </span>
          </>,
          activity?.cache_hit_ratio == null ? "—" : `${Math.round(activity.cache_hit_ratio * 100)}%`,
          "输入里走缓存的比例"
        )}
      </AsyncBlock>
    </Card>
  );

  /* ---------- 趋势 ---------- */
  const axis = trend.data?.axis;
  const buckets = trend.data ? buildBuckets(trend.data.data.rows, axis) : [];
  const unitWord = axis ? { hour: "小时", day: "天", month: "月" }[axis.granularity] : "天";
  const trendKeys = sortByToolOrder(
    [...new Set(buckets.flatMap((b) => [...b.by.keys()]))].filter((id) => buckets.some((b) => (b.by.get(id) || 0) > 0)),
    toolSeq
  );
  const trendUnallocated = trend.data?.data.unallocated?.gross_tokens ?? 0;
  const pickable = axis && axis.granularity !== "hour";
  const trendCard = (
    <Card>
      <SecHead
        title="趋势"
        sub={`每${unitWord}用了多少，颜色代表工具${pickable ? `。点柱子只看那${unitWord}` : ""}`}
      />
      <div className="px-[18px] pb-[18px] pt-3.5">
        <AsyncBlock refreshing={trend.refreshing} status={trend.status} error={trend.error} onRetry={trend.reload} rows={6}>
          <div className="flex flex-wrap gap-x-3.5 gap-y-1 text-caption text-ink-secondary">
            {trendKeys.slice(0, 8).map((key) => (
              <span key={key} className="inline-flex items-center gap-1.5">
                <i className="h-[9px] w-[9px] rounded-[3px]" style={{ background: colorOf(key) }} />
                {toolOf(key).name}
              </span>
            ))}
          </div>
          {axis ? (
            <TrendChart
              buckets={buckets}
              order={trendKeys}
              colorOf={colorOf}
              granularity={axis.granularity}
              weekdays={period.period === "week"}
              selected={selectedBucket || null}
              onPick={pickable ? (bucket) => setFilter("bucket", bucket) : null}
            />
          ) : null}
          {trendUnallocated > 0 ? (
            <p className="mt-2 text-[12.5px] text-ink-muted">
              另有 <Nt value={trendUnallocated} /> token 来自跨{unitWord}的会话快照，不在图里；上面的用量已经算上了。
            </p>
          ) : null}
        </AsyncBlock>
      </div>
    </Card>
  );

  /* ---------- 表 ---------- */
  const rows = (() => {
    const t = table.data;
    if (!t) return [];
    const kindsOf = (g) => KINDS.map(([field]) => g[field]);
    if (t.kind === "date") {
      return (t.data.points ?? [])
        .filter((p) => p.gross_tokens > 0)
        .map((p) => ({
          id: p.bucket,
          order: p.bucket,
          name: <span className="font-medium text-ink">{bucketText(p.bucket)}</span>,
          sub: null,
          tokens: p.gross_tokens,
          cost: p.cost_usd,
          kinds: kindsOf(p),
          drill: !selectedBucket && /^\d{4}-\d{2}(-\d{2})?$/.test(p.bucket) ? ["bucket", p.bucket] : null
        }));
    }
    if (t.kind === "model") {
      const byModel = new Map();
      for (const g of t.data.groups ?? []) {
        const key = g.model ?? null;
        const row = byModel.get(key) || { key, tools: new Set(), gross_tokens: 0, cost: 0, priced: false, kinds: [null, null, null, null] };
        row.tools.add(g.source);
        row.gross_tokens += g.gross_tokens;
        if (g.cost_usd != null) {
          row.cost += Number(g.cost_usd);
          row.priced = true;
        }
        KINDS.forEach(([field], i) => {
          if (g[field] != null) row.kinds[i] = (row.kinds[i] ?? 0) + g[field];
        });
        byModel.set(key, row);
      }
      return [...byModel.values()].map((r) => ({
        id: r.key ?? "—",
        name: (
          <span className="inline-flex min-w-0 items-center gap-2">
            {[...r.tools].map((id) => (
              <ToolTile key={id} id={id} size={16} />
            ))}
            <span className="font-medium text-ink">{r.key ?? "没写模型"}</span>
          </span>
        ),
        sub: [...r.tools].map((id) => toolOf(id).name).join("、"),
        tokens: r.gross_tokens,
        cost: r.priced ? r.cost : null,
        kinds: r.kinds,
        drill: !detail.model && r.key ? ["model", r.key] : null
      }));
    }
    return (t.data.groups ?? []).map((g) =>
      t.kind === "tool"
        ? {
            id: g.key,
            name: (
              <span className="inline-flex items-center gap-2.5">
                <ToolTile id={g.key} size={24} />
                <span className="font-medium text-ink">{toolOf(g.key).name}</span>
              </span>
            ),
            sub: null,
            tokens: g.gross_tokens,
            cost: g.cost_usd,
            kinds: kindsOf(g),
            drill: !detail.tool && g.key ? ["tool", g.key] : null
          }
        : {
            id: g.key ?? "—",
            name: <span className="font-medium text-ink">{projectName(g.key) ?? <span className="text-ink-muted">没有记录项目</span>}</span>,
            sub: g.key ?? "工具没有写工作目录",
            tokens: g.gross_tokens,
            cost: g.cost_usd,
            kinds: kindsOf(g),
            drill: !detail.project && g.key ? ["project", g.key] : null
          }
    );
  })();
  const sum = rows.reduce((s, r) => s + r.tokens, 0);
  const sortValue = (r) =>
    sort.key === "cost" ? Number(r.cost ?? -1) : sort.key?.startsWith("k") ? r.kinds[Number(sort.key[1])] ?? -1 : r.tokens;
  rows.sort((a, b) =>
    sort.key
      ? (sortValue(b) - sortValue(a)) * -sort.dir
      : table.data?.kind === "date"
        ? String(b.order).localeCompare(String(a.order))
        : b.tokens - a.tokens
  );
  const toggleSort = (key) => setSort((s) => (s.key === key ? { key, dir: -s.dir } : { key, dir: -1 }));
  const share = (r) => (sum ? r.tokens / sum : 0);
  const shareText = (r) => `${(share(r) * 100).toFixed(share(r) < 0.1 ? 1 : 0)}%`;
  const kindCell = (v) => (v == null ? <span className="text-ink-muted" title="客户端没有上报">—</span> : formatTokens(v));
  const tableUnallocated = table.data?.kind === "date" ? table.data.data.unallocated?.gross_tokens ?? 0 : 0;
  const dimFiltered = { date: Boolean(selectedBucket), tool: Boolean(detail.tool), model: Boolean(detail.model), project: Boolean(detail.project) }[detail.dim];

  const th = (key, label, hint) => (
    <th className="whitespace-nowrap px-2.5 py-2 text-right text-caption font-normal text-ink-muted shadow-[inset_0_-1px_0_var(--lens-line)]">
      <button
        type="button"
        onClick={() => toggleSort(key)}
        title={hint}
        aria-sort={sort.key === key ? (sort.dir > 0 ? "ascending" : "descending") : undefined}
        className={`rounded px-0.5 hover:text-ink ${sort.key === key ? "font-medium text-ink" : ""}`}
      >
        {label}
        {sort.key === key ? (sort.dir > 0 ? " ↑" : " ↓") : ""}
      </button>
    </th>
  );
  const open = (r) => r.drill && setFilter(r.drill[0], r.drill[1]);

  const tableBody = narrow ? (
    <ul className="m-0 flex list-none flex-col p-0">
      {rows.map((r) => {
        const Row = r.drill ? "button" : "div";
        return (
          <li key={r.id}>
            <Row
              {...(r.drill ? { type: "button", onClick: () => open(r) } : {})}
              className="-mx-2.5 block w-[calc(100%+20px)] rounded-xl px-2.5 py-3 text-left hover:bg-[var(--lens-fill-hover)]"
            >
              <div className="flex items-center justify-between gap-2.5">
                <span className="min-w-0 truncate">{r.name}</span>
                <b className="tabular-nums text-ink">{formatTokens(r.tokens)}</b>
              </div>
              {r.sub ? <div className="mt-0.5 truncate text-caption text-ink-muted">{r.sub}</div> : null}
              <div className="mt-1 flex flex-wrap gap-3 text-[12.5px] tabular-nums text-ink-secondary">
                <span>
                  约值 <Money value={r.cost} mono={false} />
                </span>
                <span>占 {shareText(r)}</span>
                <span>读缓存 {kindCell(r.kinds[2])}</span>
              </div>
            </Row>
          </li>
        );
      })}
    </ul>
  ) : (
    <div className="-mx-2.5 overflow-x-auto">
      <table className="w-full border-collapse text-[13px]">
        <thead>
          <tr>
            <th className="px-2.5 py-2 text-left text-caption font-normal text-ink-muted shadow-[inset_0_-1px_0_var(--lens-line)]">
              {DIM_OPTIONS.find(([k]) => k === detail.dim)[1].slice(1)}
            </th>
            {th("v", "用量")}
            {th("cost", "约值")}
            <th className="px-2.5 py-2 text-right text-caption font-normal text-ink-muted shadow-[inset_0_-1px_0_var(--lens-line)]">占比</th>
            {KINDS.map(([, label, hint], i) => th(`k${i}`, label, hint))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr
              key={r.id}
              tabIndex={r.drill ? 0 : undefined}
              onClick={() => open(r)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  open(r);
                }
              }}
              className={`${r.drill ? "cursor-pointer hover:bg-[var(--lens-fill-hover)]" : ""} transition-colors duration-fast ease-lens`}
            >
              <td className="px-2.5 py-2.5 shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                <div>{r.name}</div>
                {r.sub ? <div className="max-w-[320px] truncate text-caption text-ink-muted" title={r.sub}>{r.sub}</div> : null}
              </td>
              <td className="whitespace-nowrap px-2.5 py-2.5 text-right font-semibold tabular-nums text-ink shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                <Nt value={r.tokens} />
              </td>
              <td className="whitespace-nowrap px-2.5 py-2.5 text-right tabular-nums shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                <Money value={r.cost} mono={false} />
              </td>
              <td className="whitespace-nowrap px-2.5 py-2.5 text-right tabular-nums text-ink-secondary shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                <span className="mr-2 inline-block h-[5px] w-14 overflow-hidden rounded-pill bg-[var(--lens-fill-hover)] align-middle">
                  <i className="block h-full rounded-pill bg-clay" style={{ width: `${share(r) * 100}%` }} />
                </span>
                {shareText(r)}
              </td>
              {r.kinds.map((v, i) => (
                <td
                  key={KINDS[i][0]}
                  className="whitespace-nowrap px-2.5 py-2.5 text-right tabular-nums text-ink-secondary shadow-[inset_0_-1px_0_var(--lens-line-soft)]"
                >
                  {kindCell(v)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );

  const tableCard = (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3 px-[18px] pt-4">
        <div>
          <h2 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">拆开看</h2>
          <p className="mt-0.5 text-[12.5px] text-ink-muted">
            {dimFiltered ? "已经按这一项筛选了，换个拆法看看" : "点一行，把它加进筛选"}
          </p>
        </div>
        <Segmented
          ariaLabel="拆分方式"
          size="sm"
          value={detail.dim}
          onChange={(dim) => {
            setSort({ key: null, dir: -1 });
            go({ ...detail, dim });
          }}
          options={DIM_OPTIONS.map(([value, label]) => ({
            value,
            label: value === "date" && axis?.granularity === "hour" && !picked ? "按小时" : label
          }))}
        />
      </div>
      <div className="px-[18px] pb-[18px] pt-3">
        <AsyncBlock refreshing={table.refreshing} status={table.status} error={table.error} onRetry={table.reload} rows={5}>
          {rows.length ? tableBody : <p className="py-6 text-center text-body text-ink-muted">这段时间没有符合筛选的用量。</p>}
          {tableUnallocated > 0 ? (
            <p className="mt-2.5 text-[12.5px] text-ink-muted">
              另有 <Nt value={tableUnallocated} /> token 来自跨{unitWord}的会话快照，没法按{unitWord}拆开，不在这张表里；上面的用量已经算上了。
            </p>
          ) : null}
          <p className="mt-2.5 text-[12.5px] text-ink-muted">
            新输入：这次新发给模型的内容 · 输出：模型写回来的 · 读缓存：重复发送、命中缓存的上下文，便宜很多 ·
            写缓存：第一次写进缓存的内容。四类互不重叠，加起来就是用量。
          </p>
        </AsyncBlock>
      </div>
    </Card>
  );

  const label = periodLabel(period.period);
  return (
    <>
      <div className="mb-1 flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
        <div className="min-w-0 flex-1 basis-[420px]">
          <h1 className="font-serif text-[24px] font-medium leading-[1.25] tracking-[-0.01em] text-ink md:text-[28px]">明细</h1>
          <p className="mt-1 text-[14px] text-ink-secondary">
            {label === "全部" ? "全部时间" : label === "自定义" ? "这段时间" : label}的用量，按工具、模型、项目和时间拆开看。
          </p>
        </div>
        {controls}
      </div>
      <AsyncBlock refreshing={options.refreshing} status={options.status} error={options.error} onRetry={options.reload} rows={1}>{filterBar}</AsyncBlock>
      {strip}
      {trendCard}
      {tableCard}
      <p className="mt-1 text-xs text-ink-muted">
        金额按各模型的公开标准价估算，用来比较和感知，不是你的账单。{" "}
        <Link to="/settings" className="underline decoration-[var(--lens-line-strong)] underline-offset-2 hover:text-ink">
          价格怎么算
        </Link>
      </p>
    </>
  );
}
