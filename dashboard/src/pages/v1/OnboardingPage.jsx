import React, { useEffect, useRef, useState } from "react";
import { motion } from "motion/react";
import { ArrowRight, Check, ChevronRight, Lock } from "lucide-react";
import { ApiError, api } from "../../lib/v1";
import { syncState } from "../../lib/sync-state.js";
import { toolOf, TOOLS } from "../../lib/tools.js";
import { Button } from "../../ui/lens/Button.jsx";
import { ToolTile } from "../../ui/lens/ToolTile.jsx";
import { AsyncBlock, useFormatTokens, useResource, useSyncState } from "./shared.jsx";

function Mark48() {
  return (
    <svg width="48" height="48" viewBox="0 0 24 24" fill="none" aria-hidden="true">
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

/**
 * 首次引导：发现 → 统计中 → 完成。三步照原型 onboarding()。
 * 同步进度后端不提供，不伪造百分比：只有往返进度条和「读取中…」。
 *
 * @param {{ onEnter: () => void }} props
 */
export function OnboardingPage({ onEnter }) {
  const formatTokens = useFormatTokens();
  const sync = useSyncState();
  const [step, setStep] = useState("discover");
  const [moreOpen, setMoreOpen] = useState(false);
  const [syncError, setSyncError] = useState(null);
  const visibleSyncError = sync.error?.message ?? syncError;
  const alive = useRef(true);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const completed = useResource(() => api.summary(), [], { enabled: step === "done" });
  const doneData = completed.fresh ? completed.data : null;
  // 第一次用服务端的缓存；点「重新检测」时要求重扫，刚装好的工具才能马上出现
  const [scan, setScan] = useState(0);
  const discovery = useResource(() => api.discovery({ fresh: scan > 0 }), [scan], { ledger: false });

  const found = discovery.data?.sources ?? [];
  const supported = discovery.data?.supported ?? Object.keys(TOOLS).length;
  const missing = Object.keys(TOOLS).filter((id) => !found.some((item) => item.source === id));
  const missingCount = Math.max(0, supported - found.length);

  const startSync = async () => {
    setStep("counting");
    setSyncError(null);
    try {
      if (syncState.getSnapshot().errorKind === "status") {
        await syncState.retryStatus();
        if (alive.current) setStep(syncState.getSnapshot().phase === "success" ? "done" : "discover");
        return;
      }
      await syncState.startSync();
      if (alive.current) setStep("done");
    } catch (err) {
      if (!alive.current) return;
      setSyncError(
        err instanceof ApiError && err.status === 409
          ? "已经有一次同步在进行，稍等再试"
          : err?.message || "同步失败"
      );
      setStep("discover");
    }
  };

  const totals = doneData?.totals ?? null;
  const firstSeen = doneData?.activity?.first_seen ?? null;
  const firstSeenText = (() => {
    const d = firstSeen ? new Date(firstSeen) : null;
    return d && !Number.isNaN(d.getTime())
      ? `${d.getFullYear()} 年 ${d.getMonth() + 1} 月 ${d.getDate()} 日`
      : "—";
  })();

  return (
    <div
      className="flex h-dvh min-h-0 justify-center overflow-y-auto px-3.5 pb-10 pt-8 md:px-5 md:pt-14"
      style={{
        background:
          "radial-gradient(1200px 500px at 50% -10%, color-mix(in srgb, var(--lens-clay) 9%, transparent), transparent 70%), var(--lens-surface-0)"
      }}
    >
      <div className="mx-auto flex w-full max-w-[560px] flex-col items-center">
        {step === "done" ? (
          <>
            <div
              className="flex h-16 w-16 items-center justify-center rounded-[20px] bg-clay"
              style={{
                color: "var(--lens-tile-ink)",
                boxShadow: "0 8px 24px -6px rgb(217 119 87 / 0.55)"
              }}
            >
              <Check className="h-[30px] w-[30px]" strokeWidth={2.2} aria-hidden />
            </div>
            <h1 className="mt-[18px] text-center font-serif text-[28px] font-medium tracking-[-0.01em] text-ink md:text-[34px]">
              统计好了
            </h1>
            <p className="mt-1.5 text-center text-[16px] text-ink-secondary">
              最早的一条记录在 {firstSeenText}。更早的用量，工具已经没有保留日志，所以统计不到。
              以后每次打开都会自动补上新的用量。
            </p>

            <div className="mt-7 grid w-full grid-cols-3 overflow-hidden rounded-[14px] bg-surface-2 shadow-card">
              <div className="px-[18px] py-4">
                <div
                  className="font-serif text-[20px] font-semibold leading-[1.2] tabular-nums text-ink lg:text-[26px]"
                  title={totals ? `${Math.round(totals.gross_tokens).toLocaleString("en-US")} token` : undefined}
                >
                  {totals ? formatTokens(totals.gross_tokens) : "—"}
                </div>
                <div className="text-[12.5px] text-ink-muted">token</div>
              </div>
              <div className="px-[18px] py-4 shadow-[inset_1px_0_0_var(--lens-line-soft)]">
                <div className="font-serif text-[20px] font-semibold leading-[1.2] tabular-nums text-ink lg:text-[26px]">
                  {totals ? totals.record_count.toLocaleString("en-US") : "—"}
                </div>
                <div className="text-[12.5px] text-ink-muted">条记录</div>
              </div>
              <div className="px-[18px] py-4 shadow-[inset_1px_0_0_var(--lens-line-soft)]">
                <div className="font-serif text-[20px] font-semibold leading-[1.2] tabular-nums text-ink lg:text-[26px]">
                  {doneData ? doneData.activity.sessions.toLocaleString("en-US") : "—"}
                </div>
                <div className="text-[12.5px] text-ink-muted">个会话</div>
              </div>
            </div>

            <div className="mt-[18px] flex flex-wrap justify-center gap-1.5">
              {found.map((item) => (
                <ToolTile key={item.source} id={item.source} size={32} />
              ))}
            </div>

            <div className="mt-6 flex flex-col items-center gap-3">
              {sync.warning ? <p role="status" className="text-[12.5px] text-ink-secondary">同步完成，有异常警告：{sync.warning}</p> : null}
              {completed.status === "error" ? <AsyncBlock status={completed.status} error={completed.error} onRetry={completed.reload}>{null}</AsyncBlock> : null}
              <Button variant="primary" size="lg" className="h-11 rounded-xl px-[22px]" onClick={onEnter}>
                去看看 <ArrowRight className="h-3.5 w-3.5" aria-hidden />
              </Button>
            </div>
          </>
        ) : (
          <>
            <Mark48 />
            <h1 className="mt-[18px] text-center font-serif text-[28px] font-medium tracking-[-0.01em] text-ink md:text-[34px]">
              欢迎使用 Token Lens
            </h1>
            <p className="mt-1.5 text-center text-[16px] text-ink-secondary">
              看看你的 AI 编程工具用了多少 token、按公开价值多少钱。
            </p>

            <div className="mt-7 w-full rounded-[14px] bg-surface-2 shadow-card">
              <AsyncBlock
                status={discovery.status}
                error={discovery.error}
                onRetry={discovery.reload}
              >
                {step === "counting" ? (
                  <div className="px-[18px] pb-1.5 pt-[14px]">
                    <b className="text-[14px] text-ink">正在读取日志…</b>
                    <div className="mt-2 h-1.5 overflow-hidden rounded-pill bg-[var(--lens-fill-hover)]">
                      <motion.span
                        className="block h-full w-2/5 rounded-pill bg-clay"
                        animate={{ x: ["0%", "150%"] }}
                        transition={{ duration: 1.1, repeat: Infinity, repeatType: "reverse", ease: "easeInOut" }}
                      />
                    </div>
                  </div>
                ) : (
                  <div className="flex items-baseline justify-between px-[18px] pb-1.5 pt-4">
                    <h2 className="text-[14px] font-semibold text-ink">
                      在这台电脑上找到 {found.length} 个工具
                    </h2>
                    <span className="text-[12.5px] text-ink-muted">支持 {supported} 个</span>
                  </div>
                )}

                {found.length === 0 && step !== "counting" ? (
                  <p className="px-[18px] pb-4 pt-1 text-[13px] text-ink-muted">
                    这台电脑上还没找到支持的工具的日志。装好并用过其中任意一个后再回来。
                  </p>
                ) : (
                  <ul className="list-none px-2.5 pb-2 pt-1">
                    {found.map((item, index) => (
                      <li
                        key={item.source}
                        className={`flex items-center gap-3 rounded-[10px] px-2 py-[9px] ${
                          index > 0 ? "shadow-[inset_0_1px_0_var(--lens-line-soft)]" : ""
                        }`}
                      >
                        <ToolTile id={item.source} size={32} />
                        <div className="min-w-0 flex-1">
                          <div className="text-body font-medium text-ink">{toolOf(item.source).name}</div>
                          <div className="text-[12.5px] text-ink-muted">
                            {item.files.toLocaleString("en-US")} 个日志文件
                          </div>
                        </div>
                        {step === "counting" ? (
                          <span className="text-[12.5px] text-ink-muted">读取中…</span>
                        ) : (
                          <span className="flex items-center gap-1 text-[12.5px] text-signal-ok">
                            <Check className="h-3.5 w-3.5" aria-hidden />
                            找到
                          </span>
                        )}
                      </li>
                    ))}
                  </ul>
                )}

                {step !== "counting" && missingCount > 0 ? (
                  <>
                    <button
                      type="button"
                      aria-expanded={moreOpen}
                      onClick={() => setMoreOpen((value) => !value)}
                      className="flex w-full items-center gap-1.5 px-[18px] py-3 text-left text-[13px] text-ink-secondary shadow-[inset_0_1px_0_var(--lens-line-soft)] transition-colors duration-fast ease-lens hover:text-ink"
                    >
                      <ChevronRight
                        className={`h-3.5 w-3.5 transition-transform duration-fast ease-lens ${moreOpen ? "rotate-90" : ""}`}
                        aria-hidden
                      />
                      还有 {missingCount} 个支持的工具没在这台电脑上找到
                    </button>
                    {moreOpen ? (
                      <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 px-[18px] pb-4">
                        {missing.map((id) => (
                          <span key={id} className="flex items-center gap-2 text-[13px] text-ink-muted">
                            <span style={{ filter: "grayscale(1)", opacity: 0.65, display: "inline-flex" }}>
                              <ToolTile id={id} size={20} />
                            </span>
                            {toolOf(id).name}
                          </span>
                        ))}
                      </div>
                    ) : null}
                  </>
                ) : null}
              </AsyncBlock>
            </div>

            <div className="mt-6 flex flex-col items-center gap-3">
              {found.length === 0 && step !== "counting" ? (
                <Button variant="primary" size="lg" className="h-11 rounded-xl px-[22px]" onClick={() => setScan((n) => n + 1)}>
                  重新检测
                </Button>
              ) : (
                <Button
                  variant="primary"
                  size="lg"
                  className="h-11 rounded-xl px-[22px]"
                  disabled={step === "counting" || sync.phase === "running" || sync.phase === "conflict"}
                  onClick={startSync}
                >
                  {step === "counting" ? "统计中…" : visibleSyncError ? "重试" : "开始统计"}
                </Button>
              )}
              {visibleSyncError ? (
                <p className="max-w-[420px] text-center text-[12.5px] text-signal-danger">{visibleSyncError}</p>
              ) : null}
              <span className="flex items-center gap-1.5 text-[12.5px] text-ink-muted">
                <Lock className="h-3.5 w-3.5" aria-hidden />
                只读取本机日志，不上传任何内容，也不改动这些工具。
              </span>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
