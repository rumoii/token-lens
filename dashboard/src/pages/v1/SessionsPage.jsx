import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { ArrowRight, ChevronDown, ChevronRight, X } from "lucide-react";
import { api } from "../../lib/v1";
import { formatChineseNumber } from "../../lib/format";
import { toolOf } from "../../lib/tools.js";
import { detailSearch } from "../../lib/detail-query.js";
import { Button } from "../../ui/lens/Button.jsx";
import { EmptyState } from "../../ui/lens/EmptyState.jsx";
import { SidePanel } from "../../ui/lens/SidePanel.jsx";
import { ToolTile } from "../../ui/lens/ToolTile.jsx";
import { AsyncBlock, Money, PageScroll, useResource, useToolColors, useSyncState } from "./shared.jsx";
import { Card, Nt, useNarrow } from "./HomeParts.jsx";

const PAGE_SIZE = 50;
const KINDS = [
  ["input_tokens", "新输入"],
  ["output_tokens", "输出"],
  ["cache_read_tokens", "读缓存"],
  ["cache_write_tokens", "写缓存"]
];

const projectName = (key) => (key ? key.split(/[\\/]/).filter(Boolean).pop() : null);

function minutesBetween(startIso, endIso) {
  const start = new Date(startIso).getTime();
  const end = new Date(endIso).getTime();
  if (Number.isNaN(start) || Number.isNaN(end)) return null;
  return Math.max(0, Math.round((end - start) / 60000));
}

function spanText(startIso, endIso) {
  const minutes = minutesBetween(startIso, endIso);
  if (minutes === null) return "—";
  return minutes < 60 ? `${minutes} 分钟` : `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
}

const hm = (d) => `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;

/** 「今天」「昨天」或「10月18日 周六」。 */
function dayName(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "时间未知";
  const today = new Date();
  const k = Math.round(
    (new Date(today.getFullYear(), today.getMonth(), today.getDate()) - new Date(d.getFullYear(), d.getMonth(), d.getDate())) /
      86400000
  );
  if (k === 0) return "今天";
  if (k === 1) return "昨天";
  return `${d.getMonth() + 1}月${d.getDate()}日 周${"日一二三四五六"[d.getDay()]}`;
}

/** 开始时间：同一天只写钟点，不同天带上日期。 */
function startText(row) {
  const start = new Date(row.started_at);
  if (Number.isNaN(start.getTime())) return "—";
  return dayName(row.started_at) === dayName(row.last_seen_at) ? hm(start) : `${dayName(row.started_at)} ${hm(start)}`;
}

/**
 * 工具 / 项目筛选下拉。
 *
 * @param {{ label: string, options: Array<{ value: string, label: React.ReactNode }>, onPick: (v: string) => void }} props
 */
function Pick({ label, options, onPick }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const onDown = (event) => {
      if (!ref.current?.contains(event.target)) setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    ref.current?.querySelector("[role=menuitem]")?.focus();
    return () => document.removeEventListener("mousedown", onDown);
  }, [open]);
  return (
    <div
      ref={ref}
      className="relative"
      onKeyDown={(event) => {
        if (event.key === "Escape") setOpen(false);
        if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
        event.preventDefault();
        const items = [...(ref.current?.querySelectorAll("[role=menuitem]") ?? [])];
        const at = items.indexOf(document.activeElement);
        items[(at + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
      }}
    >
      <button
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
        <div role="menu" className="absolute left-0 top-9 z-30 max-h-[300px] min-w-[220px] overflow-y-auto rounded-xl bg-surface-3 p-1.5 shadow-pop">
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
              {option.label}
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
        className="inline-flex h-5 w-5 items-center justify-center rounded-md hover:bg-[color-mix(in_srgb,var(--lens-clay)_18%,transparent)]"
      >
        <X className="h-3.5 w-3.5" aria-hidden />
      </button>
    </span>
  );
}

function SecTitle({ title, sub }) {
  return (
    <div className="px-4 pt-3.5">
      <h3 className="text-[14.5px] font-semibold text-ink">{title}</h3>
      {sub ? <p className="mt-0.5 text-[12.5px] text-ink-muted">{sub}</p> : null}
    </div>
  );
}

/**
 * 单个会话：用量 → 用了哪些模型 → 时间线 → token 构成 → 去明细 → 技术细节。
 * 只在面板打开时挂载，所以拉取跟着面板走，不给列表页增加请求。
 */
function SessionDetail({ source, sessionId }) {
  const { colorOf } = useToolColors();
  // 会话通常跨几小时，按小时看分布
  const detail = useResource(
    () => api.sessionDetail({ source, session_id: sessionId, granularity: "hour" }),
    [source, sessionId]
  );
  if (detail.status !== "ready" || !detail.data) {
    return <AsyncBlock refreshing={detail.refreshing} status={detail.status} error={detail.error} onRetry={detail.reload} rows={6}>{null}</AsyncBlock>;
  }
  const { session, models, timeline, kinds } = detail.data;
  const cacheBase = Number(session.input_tokens || 0) + Number(session.cache_read_tokens || 0);
  const hit = cacheBase > 0 && session.cache_read_tokens != null ? session.cache_read_tokens / cacheBase : null;
  const peak = Math.max(1, ...timeline.map((p) => p.gross_tokens));
  const topModel = Math.max(1, ...models.map((m) => m.gross_tokens));
  const onlyTotals = kinds.cumulative > 0 && kinds.event === 0;
  const kindValues = KINDS.map(([field]) => session[field]);
  const kindSum = kindValues.reduce((s, v) => s + (v || 0), 0);
  const project = projectName(session.project_key);
  const detailHref = (filter) => `/dashboard?${detailSearch("period=all", filter)}`;
  const mini = (label, value) => (
    <div className="px-3.5 py-3">
      <div className="text-caption text-ink-muted">{label}</div>
      <div className="font-serif text-[19px] font-semibold tabular-nums text-ink">{value}</div>
    </div>
  );

  return (
    <AsyncBlock refreshing={detail.refreshing} status={detail.status} error={detail.error} onRetry={detail.reload}>
      <Card className="grid grid-cols-3 [&>*+*]:shadow-[inset_1px_0_0_var(--lens-line-soft)]">
        {mini("用量", <Nt value={session.gross_tokens} />)}
        {mini("约值", <Money value={session.cost_usd} mono={false} />)}
        {mini("缓存命中", hit === null ? "—" : `${Math.round(hit * 100)}%`)}
      </Card>

      <Card>
        <SecTitle title="用了哪些模型" />
        <ul className="m-0 flex list-none flex-col gap-2.5 p-4 pt-3">
          {models.map((m) => (
            <li key={String(m.model)}>
              <div className="flex items-center gap-2 text-[13px]">
                <span className="min-w-0 flex-1 truncate font-medium text-ink">{m.model ?? "没写模型"}</span>
                <span className="tabular-nums text-ink-secondary">
                  <Nt value={m.gross_tokens} />
                </span>
                <span className="w-16 text-right tabular-nums text-ink-muted">
                  <Money value={m.cost_usd} state={m.price_state} mono={false} />
                </span>
              </div>
              <div className="mt-1.5 h-[5px] overflow-hidden rounded-pill bg-[var(--lens-fill-hover)]">
                <i className="block h-full rounded-pill" style={{ width: `${(m.gross_tokens / topModel) * 100}%`, background: colorOf(source) }} />
              </div>
            </li>
          ))}
        </ul>
      </Card>

      <Card>
        <SecTitle title="时间线" sub={onlyTotals || timeline.length === 0 ? null : "这次会话里每小时用了多少"} />
        <div className="p-4 pt-3">
          {onlyTotals || timeline.length === 0 ? (
            <p className="m-0 text-[13px] text-ink-muted">
              {toolOf(source).name} 只记录每个会话的总数，没有每次请求的时间，所以画不出时间线。
            </p>
          ) : (
            <>
              <div className="flex h-[70px] items-end gap-0.5" role="img" aria-label="会话时间线">
                {timeline.map((p) => (
                  <i
                    key={p.bucket}
                    title={`${Number(p.bucket.slice(11, 13))}:00 · ${formatChineseNumber(p.gross_tokens)} token`}
                    className="min-w-[2px] flex-1 rounded-t-[3px] bg-clay opacity-85"
                    style={{ height: `${Math.max(6, (p.gross_tokens / peak) * 100)}%` }}
                  />
                ))}
              </div>
              <div className="mt-1 flex justify-between text-[11px] text-ink-faint">
                <span>{hm(new Date(session.started_at))}</span>
                <span>{hm(new Date(session.last_seen_at))}</span>
              </div>
            </>
          )}
        </div>
      </Card>

      <Card>
        <SecTitle title="token 是怎么构成的" sub="大部分是重复发送的上下文，命中缓存后便宜很多" />
        <div className="p-4 pt-3">
          {kindSum > 0 ? (
            <div className="flex h-2.5 gap-0.5 overflow-hidden rounded-pill" role="img" aria-label="token 构成">
              {kindValues.map((v, i) =>
                v ? <i key={KINDS[i][0]} className="block h-full" style={{ width: `${(v / kindSum) * 100}%`, background: `var(--lens-cat-${i + 1})` }} /> : null
              )}
            </div>
          ) : null}
          <div className="mt-2.5 flex flex-wrap gap-x-3.5 gap-y-1 text-caption text-ink-secondary">
            {kindValues.map((v, i) => (
              <span key={KINDS[i][0]} className="inline-flex items-center gap-1.5">
                <i className="h-[9px] w-[9px] rounded-[3px]" style={{ background: `var(--lens-cat-${i + 1})` }} />
                {KINDS[i][1]}
                <b className="font-medium tabular-nums">{v == null ? "—" : formatChineseNumber(v)}</b>
              </span>
            ))}
          </div>
        </div>
      </Card>

      <div className="flex flex-wrap gap-2">
        {session.project_key ? (
          <Link
            to={detailHref({ project: session.project_key })}
            className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-[var(--lens-fill-hover)] px-3 text-[13px] font-medium text-ink no-underline hover:bg-[var(--lens-fill-active)]"
          >
            在明细里看 {project} <ArrowRight className="h-3.5 w-3.5" aria-hidden />
          </Link>
        ) : null}
        <Link
          to={detailHref({ tool: source, dim: "model" })}
          className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-[var(--lens-fill-hover)] px-3 text-[13px] font-medium text-ink no-underline hover:bg-[var(--lens-fill-active)]"
        >
          在明细里看 {toolOf(source).name} <ArrowRight className="h-3.5 w-3.5" aria-hidden />
        </Link>
      </div>

      <details className="group rounded-xl bg-[var(--lens-fill-hover)]">
        <summary className="flex cursor-pointer list-none items-center gap-1.5 rounded-xl px-3.5 py-2.5 text-[13px] text-ink-secondary [&::-webkit-details-marker]:hidden">
          <ChevronRight className="h-3.5 w-3.5 transition-transform duration-fast group-open:rotate-90" aria-hidden />
          技术细节
        </summary>
        <dl className="m-0 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3.5 gap-y-1 px-3.5 pb-3 text-[12.5px] text-ink-secondary">
          <dt className="text-ink-muted">会话 ID</dt>
          <dd className="m-0 break-all font-mono text-[12px]">{session.session_id}</dd>
          <dt className="text-ink-muted">工作目录</dt>
          <dd className="m-0 break-all font-mono text-[12px]">{session.project_key ?? "工具没有写进日志"}</dd>
          <dt className="text-ink-muted">记录</dt>
          <dd className="m-0">
            {session.record_count} 条{onlyTotals ? "（这个工具每个会话只写一条总数）" : "，每次请求一条"}
          </dd>
          <dt className="text-ink-muted">来源</dt>
          <dd className="m-0 font-mono text-[12px]">{source}</dd>
        </dl>
      </details>
    </AsyncBlock>
  );
}

/**
 * 会话页：每次打开 AI 工具做的一件事，按最近活跃排序、按天分组。
 * 标题用项目名（工作目录的最后一级）；会话 ID、完整路径放进详情的「技术细节」。
 * `?tool=&project=` 是筛选；`?source=&session=` 直接打开那一条（首页「最近会话」用）。
 */
export function SessionsPage() {
  const narrow = useNarrow();
  const [params, setParams] = useSearchParams();
  const tool = params.get("tool") || "";
  const project = params.get("project") || "";
  const { version } = useSyncState();
  const pageIdentity = JSON.stringify([version, tool, project]);
  const [pagination, setPagination] = useState({ identity: pageIdentity, cursor: null, history: [] });
  const samePage = pagination.identity === pageIdentity;
  if (!samePage) setPagination({ identity: pageIdentity, cursor: null, history: [] });
  const cursor = samePage ? pagination.cursor : null;
  const history = samePage ? pagination.history : [];

  const [opened, setOpenedState] = useState(() => {
    const source = params.get("source");
    const sessionId = params.get("session");
    return source && sessionId ? { source, sessionId } : null;
  });

  const setOpened = (next) => {
    setOpenedState(next);
    if (!next && (params.has("source") || params.has("session"))) {
      const rest = new URLSearchParams(params);
      rest.delete("source");
      rest.delete("session");
      setParams(rest, { replace: true });
    }
  };
  const setFilter = (key, value) => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);

    setParams(next);
  };

  const load = useCallback(
    () =>
      api.sessions({
        limit: PAGE_SIZE,
        ...(cursor ? { cursor } : {}),
        ...(tool ? { source: tool } : {}),
        ...(project ? { project } : {})
      }),
    [cursor, tool, project]
  );
  const page = useResource(load, [load]);
  const sources = useResource(() => api.sources(), []);
  const projects = useResource(() => api.breakdown("project"), []);

  const items = [...history, ...(page.fresh ? page.data?.items || [] : [])];
  const nextCursor = page.fresh ? page.data?.next_cursor ?? null : null;
  const loadMore = () => {
    if (!nextCursor) return;
    setPagination({ identity: pageIdentity, history: items, cursor: nextCursor });
  };

  const groups = [];
  for (const row of items) {
    const key = dayName(row.last_seen_at);
    const last = groups[groups.length - 1];
    if (last && last.key === key) last.rows.push(row);
    else groups.push({ key, rows: [row] });
  }
  const rowKey = (row) => `${row.source}:${row.session_id}`;
  const openRow = (row) => setOpened({ source: row.source, sessionId: row.session_id });
  const isOpen = (row) => opened && opened.source === row.source && opened.sessionId === row.session_id;
  const title = (row) => projectName(row.project_key) || <span className="text-ink-muted">没有记录项目</span>;

  const toolOptions = (sources.data?.sources ?? [])
    .filter((s) => s.records > 0)
    .map((s) => ({
      value: s.source,
      label: (
        <>
          <ToolTile id={s.source} size={16} />
          {toolOf(s.source).name}
        </>
      )
    }));
  const projectOptions = (projects.data?.groups ?? [])
    .filter((g) => g.key)
    .sort((a, b) => b.gross_tokens - a.gross_tokens)
    .map((g) => ({ value: g.key, label: <span className="truncate" title={g.key}>{projectName(g.key)}</span> }));

  const filterBar = (
    <div className="flex flex-wrap items-center gap-2">
      <Pick label="工具" options={toolOptions} onPick={(v) => setFilter("tool", v)} />
      <Pick label="项目" options={projectOptions} onPick={(v) => setFilter("project", v)} />
      {tool ? (
        <Tag label="工具" onRemove={() => setFilter("tool", "")}>
          <ToolTile id={tool} size={16} />
          {toolOf(tool).name}
        </Tag>
      ) : null}
      {project ? (
        <Tag label="项目" onRemove={() => setFilter("project", "")}>
          <span title={project}>{projectName(project)}</span>
        </Tag>
      ) : null}
    </div>
  );

  const rowCells = "px-2.5 py-2.5 shadow-[inset_0_-1px_0_var(--lens-line-soft)]";
  const list = narrow ? (
    <ul className="m-0 flex list-none flex-col p-0">
      {groups.map((g) => (
        <li key={g.key}>
          <div className="px-1 pb-1.5 pt-3.5 text-caption font-medium text-ink-muted first:pt-0.5">{g.key}</div>
          <ul className="m-0 list-none p-0">
            {g.rows.map((row) => (
              <li key={rowKey(row)}>
                <button
                  type="button"
                  data-session={rowKey(row)}
                  onClick={() => openRow(row)}
                  aria-label={`查看会话：${projectName(row.project_key) || "没有记录项目"}，${toolOf(row.source).name}`}
                  className={`-mx-2.5 flex w-[calc(100%+20px)] items-start gap-3 rounded-xl px-2.5 py-3 text-left hover:bg-[var(--lens-fill-hover)] ${isOpen(row) ? "bg-[var(--lens-fill-hover)]" : ""}`}
                >
                  <ToolTile id={row.source} size={32} />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center justify-between gap-2.5">
                      <span className="truncate text-[14px] font-medium text-ink">{title(row)}</span>
                      <b className="text-[14px] tabular-nums text-ink">{formatChineseNumber(row.gross_tokens)}</b>
                    </span>
                    <span className="block text-caption text-ink-muted">{toolOf(row.source).name}</span>
                    <span className="mt-1 flex flex-wrap gap-3 text-[12.5px] tabular-nums text-ink-secondary">
                      <span>{startText(row)} 开始</span>
                      <span>{spanText(row.started_at, row.last_seen_at)}</span>
                      <span>
                        约值 <Money value={row.cost_usd} mono={false} />
                      </span>
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </li>
      ))}
    </ul>
  ) : (
    <table className="w-full border-collapse text-[13px]">
      <thead>
        <tr className="text-left text-caption text-ink-muted">
          <th className="px-2.5 py-2 font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">会话</th>
          <th className="px-2.5 py-2 font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">开始</th>
          <th className="px-2.5 py-2 text-right font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">时长</th>
          <th className="px-2.5 py-2 text-right font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">用量</th>
          <th className="px-2.5 py-2 text-right font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">约值</th>
        </tr>
      </thead>
      {groups.map((g) => (
        <tbody key={g.key}>
          <tr>
            <td colSpan={5} className="px-2.5 pb-1.5 pt-4 text-caption font-medium text-ink-muted">
              {g.key}
            </td>
          </tr>
          {g.rows.map((row) => (
            <tr
              key={rowKey(row)}
              tabIndex={0}
              data-session={rowKey(row)}
              onClick={() => openRow(row)}
              onKeyDown={(event) => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                openRow(row);
              }}
              aria-label={`查看会话：${projectName(row.project_key) || "没有记录项目"}，${toolOf(row.source).name}`}
              className={`cursor-pointer transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] focus-visible:bg-[var(--lens-fill-hover)] ${isOpen(row) ? "bg-[var(--lens-fill-hover)]" : ""}`}
            >
              <td className={rowCells}>
                <div className="flex min-w-0 items-center gap-2.5">
                  <ToolTile id={row.source} size={28} />
                  <div className="min-w-0">
                    <div className="truncate font-medium text-ink">{title(row)}</div>
                    <div className="text-caption text-ink-muted">{toolOf(row.source).name}</div>
                  </div>
                </div>
              </td>
              <td className={`${rowCells} whitespace-nowrap tabular-nums text-ink-secondary`}>{startText(row)}</td>
              <td className={`${rowCells} whitespace-nowrap text-right text-ink-secondary`}>{spanText(row.started_at, row.last_seen_at)}</td>
              <td className={`${rowCells} whitespace-nowrap text-right font-semibold tabular-nums text-ink`}>
                <Nt value={row.gross_tokens} />
              </td>
              <td className={`${rowCells} whitespace-nowrap text-right tabular-nums text-ink-secondary`}>
                <Money value={row.cost_usd} mono={false} />
              </td>
            </tr>
          ))}
        </tbody>
      ))}
    </table>
  );

  return (
    <PageScroll>
      <div className="flex flex-col gap-3 md:gap-4">
        <div>
          <h1 className="font-serif text-[24px] font-medium leading-[1.25] tracking-[-0.01em] text-ink md:text-[28px]">会话</h1>
          <p className="mt-1 text-[14px] text-ink-secondary">
            每次打开 AI 工具做的一件事，最近的在最上面。点一个看它用了哪些模型、花在什么时候。
          </p>
        </div>
        <AsyncBlock refreshing={projects.refreshing} status={projects.status} error={projects.error} onRetry={projects.reload} rows={1}>
          <AsyncBlock refreshing={sources.refreshing} status={sources.status} error={sources.error} onRetry={sources.reload} rows={1}>
            {filterBar}
          </AsyncBlock>
        </AsyncBlock>
        <Card className="px-[18px] pb-4 pt-2">
          <AsyncBlock refreshing={page.refreshing} status={page.refreshing && history.length === 0 ? "loading" : page.status} error={page.error} onRetry={page.reload} rows={6}>
            {items.length === 0 ? (
              <div className="py-4">
                <EmptyState
                  title="还没有会话"
                  hint={tool || project ? "换个筛选看看。" : "同步之后，工具记录的每个会话都会出现在这里。"}
                />
              </div>
            ) : (
              list
            )}
          </AsyncBlock>
          {items.length > 0 ? (
            <div className="mt-3 flex items-center justify-between gap-3">
              <span className="text-caption text-ink-muted">已显示 {items.length} 个会话</span>
              {nextCursor ? (
                <Button variant="secondary" size="sm" onClick={loadMore}>
                  加载更多
                </Button>
              ) : (
                <span className="text-caption text-ink-muted">已经是全部了</span>
              )}
            </div>
          ) : null}
        </Card>
        <p className="text-xs text-ink-muted">
          有些工具（比如 DSH）只记录每个会话的总数，这类会话看不到时间线；会话按最后一次活动的那天分组。
        </p>
      </div>

      <SidePanel
        open={Boolean(opened)}
        label="会话详情"
        icon={opened ? <ToolTile id={opened.source} size={40} /> : null}
        title={opened ? sessionTitle(items, opened) : ""}
        hint={opened ? sessionHint(items, opened) : null}
        onClose={() => setOpened(null)}
      >
        {opened ? <SessionDetail source={opened.source} sessionId={opened.sessionId} /> : null}
      </SidePanel>
    </PageScroll>
  );
}

function findRow(items, opened) {
  return items.find((r) => r.source === opened.source && r.session_id === opened.sessionId) ?? null;
}

function sessionTitle(items, opened) {
  const row = findRow(items, opened);
  return (row && projectName(row.project_key)) || (row ? "没有记录项目" : "会话详情");
}

function sessionHint(items, opened) {
  const row = findRow(items, opened);
  if (!row) return toolOf(opened.source).name;
  return `${toolOf(row.source).name} · ${dayName(row.started_at)} ${hm(new Date(row.started_at))}–${hm(new Date(row.last_seen_at))} · ${spanText(row.started_at, row.last_seen_at)}`;
}
