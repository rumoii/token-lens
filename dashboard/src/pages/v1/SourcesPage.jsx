import { useEffect, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { ArrowRight, Check, ChevronRight, RefreshCw } from "lucide-react";
import { api } from "../../lib/v1";
import { formatChineseNumber } from "../../lib/format";
import { periodRange } from "../../lib/period.js";
import { TOOLS, toolOf } from "../../lib/tools.js";
import { syncState } from "../../lib/sync-state.js";
import { EmptyState } from "../../ui/lens/EmptyState.jsx";
import { ToolTile } from "../../ui/lens/ToolTile.jsx";
import { AsyncBlock, RelativeTime, PageScroll, useResource, useSyncState } from "./shared.jsx";
import { Card } from "./HomeParts.jsx";

const RECORD_MODE = {
  event: ["每次请求都有记录", "能看到每次请求的时间、模型和用量。"],
  cumulative: ["只记录每个会话的总数", "能看到每个会话用了多少，看不到会话里每次请求的时间。"],
  mixed: ["大多按请求记录", "有的会话只有一条总数，这些会话看不到时间线。"]
};

/** 账本自检各项的说法；值为 [前半句, 单位]。 */
const CHECKS = {
  time_out_of_range: ["时间不在合理范围", "条"],
  huge_requests: ["单次请求超过 1 亿 token", "条"],
  null_model: ["没有模型名、不计价", "条"],
  mixed_kind_sessions: ["同一会话混用两种记录方式", "个会话"]
};

const pill = "inline-flex h-5 items-center gap-1 whitespace-nowrap rounded-pill px-[7px] text-[11.5px] font-medium";
const okPill = `${pill} text-signal-ok bg-[color-mix(in_srgb,var(--lens-ok)_12%,transparent)]`;
const warnPill = `${pill} text-signal-warn bg-[color-mix(in_srgb,var(--lens-warn)_14%,transparent)]`;
const plainPill = `${pill} bg-[var(--lens-fill-hover)] text-ink-secondary`;

function Tech({ title = "技术细节", children }) {
  return (
    <details className="group rounded-xl bg-[var(--lens-fill-hover)]">
      <summary className="flex cursor-pointer list-none items-center gap-1.5 rounded-xl px-3.5 py-2.5 text-[13px] text-ink-secondary [&::-webkit-details-marker]:hidden">
        <ChevronRight className="h-3.5 w-3.5 transition-transform duration-fast group-open:rotate-90" aria-hidden />
        {title}
      </summary>
      <div className="px-3.5 pb-3 text-[12.5px] text-ink-secondary">{children}</div>
    </details>
  );
}

/** 同步状态写成一句话：从没同步、正在同步、正常、有异常。 */
function runSentence(run) {
  if (!run) return "还没有同步过";
  if (run.status === "running") return "正在同步…";
  if (run.status === "ok") return null;
  return run.anomaly_count > 0 ? `上次同步有 ${run.anomaly_count} 处没读成功，其余已经更新` : "上次同步没有完成";
}

/**
 * 工具页：这台电脑上找到的 AI 编程工具，以及每个工具的日志能统计到什么程度。
 * 来源一律用友好名；证据等级、累计型这些说法改成人话，原文收进「技术细节」。
 */
export function SourcesPage() {
  const { hash } = useLocation();
  const sources = useResource(() => api.sources(), []);
  const month = useResource(() => {
    const range = periodRange({ period: "month" });
    return api.breakdown("source", { from: range.from, to: range.to });
  }, []);
  const sync = useSyncState();
  const syncing = sync.phase === "running" || sync.phase === "conflict";
  // 同步成功时让状态点重播一圈扩散（lens-pulse-ok，key 换掉重挂载）
  const pulse = sync.version;
  const [highlight, setHighlight] = useState(null);
  const [moreOpen, setMoreOpen] = useState(false);

  // 带 #tool-<source> 进来时滚到对应卡片并高亮 2 秒
  useEffect(() => {
    const id = hash && hash.startsWith("#tool-") ? hash.slice(1) : null;
    if (!id) return undefined;
    const el = document.getElementById(id);
    if (!el) return undefined;
    el.scrollIntoView({ block: "start" });
    setHighlight(id);
    const timer = setTimeout(() => setHighlight(null), 2000);
    return () => clearTimeout(timer);
  }, [hash, sources.status]);

  const runSync = () => {
    if (sync.errorKind === "status") syncState.retryStatus();
    else syncState.startSync().catch(() => {});
  };

  const list = (sources.data?.sources || []).filter((item) => item.records > 0);
  const monthBy = new Map((month.data?.groups ?? []).map((g) => [g.key, g.gross_tokens]));
  list.sort((a, b) => (monthBy.get(b.source) || 0) - (monthBy.get(a.source) || 0) || b.records - a.records);
  const found = new Set(list.map((item) => item.source));
  const missing = Object.keys(TOOLS).filter((id) => !found.has(id));
  const run = sources.data?.last_run ?? null;
  const problem = runSentence(run);

  const status = (
    <Card className="flex flex-wrap items-center gap-3 px-[18px] py-3.5">
      <span
        key={pulse}
        aria-hidden
        className={`h-[7px] w-[7px] shrink-0 rounded-full ${pulse > 0 ? "lens-pulse-ok" : ""}`}
        style={{
          background: problem ? (run && run.status !== "running" ? "var(--lens-warn)" : "var(--lens-text-faint)") : "var(--lens-ok)",
          boxShadow: problem ? undefined : "0 0 0 3px color-mix(in srgb, var(--lens-ok) 18%, transparent)"
        }}
      />
      <div className="min-w-0 flex-1">
        <b className="font-medium text-ink">
          {problem ?? (
            <>
              <RelativeTime iso={run.finished_at} />同步过，一切正常
            </>
          )}
        </b>
        <div className="text-[12.5px] text-ink-muted">每次打开 Token Lens 会自动同步一次，也可以手动同步。</div>
      </div>
      <button
        type="button"
        onClick={runSync}
        disabled={syncing}
        className="inline-flex h-[34px] items-center gap-1.5 rounded-[10px] bg-clay px-3.5 text-[13.5px] font-medium text-white shadow-[0_1px_2px_rgb(0_0_0/0.1)] transition-colors duration-fast ease-lens hover:bg-clay-hover disabled:opacity-60"
      >
        <RefreshCw className={`h-3.5 w-3.5 ${syncing ? "animate-spin" : ""}`} aria-hidden />
        {syncing ? "同步中…" : "立即同步"}
      </button>
      {sync.phase === "success" && sync.result ? (
        <p className="m-0 w-full text-[12.5px] text-ink-secondary">
          同步完成：扫描 {sync.result.fileCount} 个文件，新增 {sync.result.inserted} 条，有变化的 {sync.result.updated} 条，用时{" "}
          {(sync.result.durationMs / 1000).toFixed(1)} 秒。
        </p>
      ) : null}
      {sync.phase === "conflict" ? <p role="status">已有同步在执行，正在等待完成</p> : null}
      {sync.warning ? <p role="status" className="m-0 w-full text-[12.5px] text-ink-secondary">同步完成，有异常警告：{sync.warning}</p> : null}
      {sync.phase === "error" || sync.phase === "timed_out" ? (
        <p className="m-0 w-full text-[12.5px] text-signal-danger">
          同步失败：{sync.error?.message || "请求失败"}
        </p>
      ) : null}
      {run ? (
        <div className="w-full">
          <Tech title="上次同步的技术细节">
            读了 {run.attempted.toLocaleString("en-US")} 条记录：新增 {run.inserted} 条，有变化的 {run.updated} 条，没变的{" "}
            {run.unchanged.toLocaleString("en-US")} 条，跳过 {run.rejected} 条。
            {run.anomalies?.length ? (
              <ul className="mb-0 mt-1.5 list-disc pl-4 font-mono text-[12px]">
                {run.anomalies.map((a) => (
                  <li key={a} className="break-all">
                    {a}
                  </li>
                ))}
              </ul>
            ) : null}
          </Tech>
        </div>
      ) : null}
    </Card>
  );

  const card = (item) => {
    const real = item.evidence === "A";
    const [modeTitle, modeHint] = RECORD_MODE[item.record_mode] || RECORD_MODE.event;
    const notes = item.notes ?? [];
    const retention = item.retention;
    const flagged = Object.entries(item.checks ?? {}).filter(([key, count]) => CHECKS[key] && count > 0);
    return (
      <Card
        key={item.source}
        className={`flex flex-col gap-3 px-[18px] pb-3.5 pt-4 ${highlight === `tool-${item.source}` ? "ring-2 ring-clay" : ""}`}
      >
        <div id={`tool-${item.source}`} className="flex items-center gap-3">
          <ToolTile id={item.source} size={40} />
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <b className="text-[15px] font-semibold text-ink">{toolOf(item.source).name}</b>
              <span className={okPill}>
                <Check className="h-3 w-3" aria-hidden />
                正在统计
              </span>
            </div>
            <div className="text-[12.5px] text-ink-muted">
              最近一次使用 <RelativeTime iso={item.last_observed_at} /> · 本月 {formatChineseNumber(monthBy.get(item.source) || 0)} token ·{" "}
              {item.records.toLocaleString("en-US")} 条记录
            </div>
          </div>
          <Link
            to={`/dashboard?view=detail&tool=${encodeURIComponent(item.source)}&dim=model`}
            className="inline-flex shrink-0 items-center gap-1 rounded-md px-1.5 py-0.5 text-[12.5px] text-ink-muted no-underline hover:bg-[var(--lens-fill-hover)] hover:text-ink"
          >
            看用量 <ArrowRight className="h-3 w-3" aria-hidden />
          </Link>
        </div>

        <dl className="m-0 flex flex-col gap-2 text-[13px]">
          <div className="flex items-start gap-2.5">
            <dt className="w-[72px] shrink-0 pt-px text-[12.5px] text-ink-muted">记录方式</dt>
            <dd className="m-0 min-w-0 flex-1 text-ink">
              {modeTitle}
              <div className="text-[12.5px] text-ink-muted">{modeHint}</div>
            </dd>
          </div>
          <div className="flex items-start gap-2.5">
            <dt className="w-[72px] shrink-0 pt-px text-[12.5px] text-ink-muted">核对情况</dt>
            <dd className="m-0 min-w-0 flex-1">
              {real ? (
                <span className={okPill}>
                  <Check className="h-3 w-3" aria-hidden />
                  用真实日志核对过
                </span>
              ) : (
                <span className={plainPill}>只用样例日志核对过</span>
              )}
              <div className="mt-0.5 text-[12.5px] text-ink-muted">
                {real ? "拿真实使用的日志逐条对过，数字可靠。" : "格式按公开资料和样例确认，大概率没问题；对不上的话可以反馈。"}
              </div>
            </dd>
          </div>
          {retention ? (
            <div className="flex items-start gap-2.5">
              <dt className="w-[72px] shrink-0 pt-px text-[12.5px] text-ink-muted">日志留存</dt>
              <dd className="m-0 min-w-0 flex-1 text-ink">
                {retention.logs_gone === 0
                  ? "全部记录都还能对照原始日志复核"
                  : `${retention.reviewable.toLocaleString("en-US")} 条还能对照原始日志复核`}
                {retention.logs_gone > 0 ? (
                  <div className="text-[12.5px] text-ink-muted">
                    另有 {retention.logs_gone.toLocaleString("en-US")} 条的日志已经不在了，照常计入总数，但没法再复核。
                  </div>
                ) : null}
              </dd>
            </div>
          ) : null}
          {item.checks ? (
            <div className="flex items-start gap-2.5">
              <dt className="w-[72px] shrink-0 pt-px text-[12.5px] text-ink-muted">自检</dt>
              <dd className="m-0 min-w-0 flex-1">
                {flagged.length === 0 ? (
                  <span className={plainPill}>没发现异常</span>
                ) : (
                  <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
                    {flagged.map(([key, count]) => (
                      <li key={key} className="flex items-start gap-2">
                        <span className={`${warnPill} mt-px`}>待查</span>
                        <span className="text-ink">
                          {CHECKS[key][0]}：{count.toLocaleString("en-US")} {CHECKS[key][1]}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </dd>
            </div>
          ) : null}
          {notes.length ? (
            <div className="flex items-start gap-2.5">
              <dt className="w-[72px] shrink-0 pt-px text-[12.5px] text-ink-muted">要知道的</dt>
              <dd className="m-0 min-w-0 flex-1">
                <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
                  {notes.map((note) => (
                    <li key={note.text} className="flex items-start gap-2">
                      <span className={`${note.impact === "affects" ? warnPill : plainPill} mt-px`}>
                        {note.impact === "affects" ? "有影响" : "已处理"}
                      </span>
                      <span className="text-ink">{note.text}</span>
                    </li>
                  ))}
                </ul>
              </dd>
            </div>
          ) : null}
        </dl>

        <Tech>
          <dl className="m-0 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3.5 gap-y-1">
            <dt className="text-ink-muted">来源 ID</dt>
            <dd className="m-0 font-mono text-[12px]">{item.source}</dd>
            <dt className="text-ink-muted">证据等级</dt>
            <dd className="m-0">{real ? "A（真实样本）" : "B（合成样本）"}</dd>
            {item.limits?.length ? (
              <>
                <dt className="text-ink-muted">口径原文</dt>
                <dd className="m-0">
                  {item.limits.map((limit) => (
                    <div key={limit}>{limit}</div>
                  ))}
                </dd>
              </>
            ) : null}
          </dl>
        </Tech>
      </Card>
    );
  };

  return (
    <PageScroll>
      <div className="flex flex-col gap-3 md:gap-4">
        <div>
          <h1 className="font-serif text-[24px] font-medium leading-[1.25] tracking-[-0.01em] text-ink md:text-[28px]">工具</h1>
          <p className="mt-1 text-[14px] text-ink-secondary">
            {list.length ? `这台电脑上找到 ${list.length} 个 AI 编程工具。` : ""}Token Lens 只读它们的日志，不上传，也不改动这些工具。
          </p>
        </div>
        {status}
        <AsyncBlock refreshing={month.refreshing} status={month.status} error={month.error} onRetry={month.reload} rows={1}>
        <AsyncBlock refreshing={sources.refreshing} status={sources.status} error={sources.error} onRetry={sources.reload} rows={5}>
          {list.length === 0 ? (
            <Card className="p-4">
              <EmptyState title="还没找到工具的日志" hint="用过支持的 AI 编程工具以后，点「立即同步」。" />
            </Card>
          ) : (
            <div className="grid grid-cols-1 items-start gap-3 lg:grid-cols-2 lg:gap-4">{list.map(card)}</div>
          )}
        </AsyncBlock>
        </AsyncBlock>
        {missing.length ? (
          <Card>
            <button
              type="button"
              aria-expanded={moreOpen}
              onClick={() => setMoreOpen((v) => !v)}
              className="flex w-full items-center gap-1.5 px-[18px] py-3.5 text-left text-[13.5px] text-ink-secondary hover:text-ink"
            >
              <ChevronRight className={`h-3.5 w-3.5 transition-transform duration-fast ${moreOpen ? "rotate-90" : ""}`} aria-hidden />
              还有 {missing.length} 个支持的工具没在这台电脑上找到
            </button>
            {moreOpen ? (
              <>
                <div className="grid grid-cols-2 gap-x-4 gap-y-2 px-[18px] pb-3 md:grid-cols-4">
                  {missing.map((id) => (
                    <span key={id} className="flex items-center gap-2 text-[13px] text-ink-muted">
                      <span className="opacity-60 grayscale">
                        <ToolTile id={id} size={20} />
                      </span>
                      {toolOf(id).name}
                    </span>
                  ))}
                </div>
                <p className="m-0 px-[18px] pb-4 text-[12.5px] text-ink-muted">装上并用过一次以后，点「立即同步」就会出现在上面。</p>
              </>
            ) : null}
          </Card>
        ) : null}
      </div>
    </PageScroll>
  );
}
