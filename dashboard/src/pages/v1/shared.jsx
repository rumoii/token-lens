import { useCallback, useContext, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { AlertCircle } from "lucide-react";
import { ApiError, api, invalidateReadRequests } from "../../lib/v1";
import { OTHER_COLOR, assignToolColors, toolOrder } from "../../lib/tool-colors";
import { syncState } from "../../lib/sync-state.js";
import { formatUsdCurrency } from "../../lib/format";
import { formatTokenCount } from "../../lib/token-format.js";
import { Button } from "../../ui/lens/Button.jsx";
import { SkeletonLines } from "../../ui/lens/EmptyState.jsx";
import { useCurrency } from "../../ui/foundation/CurrencyProvider.jsx";
import { TokenFormatContext } from "../../ui/foundation/TokenFormatProvider.jsx";

export function useSyncState() {
  return useSyncExternalStore(syncState.subscribe, syncState.getSnapshot);
}

/**
 * 按当前参数与账本版本读取；旧请求在参数变化、版本变化或卸载后失去提交资格。
 * @param {() => Promise<any>} loader
 * @param {any[]} deps
 */
export function useResource(loader, deps = [], { ledger = true, enabled = true } = {}) {
  const snapshot = useSyncState();
  const version = ledger ? snapshot.version : null;
  const [state, setState] = useState({ status: "loading", refreshing: false, data: null, error: null, key: null });
  const seq = useRef(0);
  const identity = useMemo(() => ({}), [...deps, version, enabled]);
  const current = useRef(null);
  const previous = useRef(null);
  current.current = { loader, identity, version, enabled };

  const run = useCallback(async () => {
    const ticket = ++seq.current;
    const captured = current.current;
    if (!captured.enabled) return;
    const valid = () => ticket === seq.current && current.current?.identity === captured.identity
      && (!ledger || syncState.getSnapshot().version === captured.version);
    // 已经有内容时重新加载不清空：切周期、点重试都不该让整块退回骨架
    setState((prev) => ({
      status: prev.data === null ? "loading" : "ready",
      refreshing: true,
      data: prev.data,
      error: null,
      key: prev.key
    }));
    try {
      const data = await captured.loader();
      if (valid()) setState({ status: "ready", refreshing: false, data, error: null, key: captured.identity });
    } catch (err) {
      if (!valid()) return;
      setState({ status: "error", refreshing: false, data: null, error: err, key: captured.identity });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ledger]);

  useEffect(() => {
    if (previous.current && previous.current.version === version && previous.current.identity !== identity) invalidateReadRequests();
    previous.current = { identity, version };
    run();
    return () => { seq.current++; };
  }, [run, identity, version]);

  const reload = useCallback(() => {
    invalidateReadRequests();
    return run();
  }, [run]);

  // `fresh`：手上的数据就是按当前 deps 取回来的。保留旧数据的那段时间里它为 false，
  // 需要把几份数据合起来算的地方据此避免新旧混算
  const fresh = state.status === "ready" && state.key === identity && !state.refreshing;
  return { ...state, fresh, version, refreshing: enabled && (state.refreshing || state.key !== identity), reload };
}

/**
 * 图表里每个工具的颜色和固定的堆叠顺序，按工具第一次出现的先后定（lib/tool-colors）。
 * 同步完成后重取一次，新出现的工具接到最后。`/sources` 的并发请求在客户端合并，多处调用不会多发。
 *
 * @returns {{ order: string[], colorOf: (id: string) => string }}
 */
export function useToolColors() {
  const sources = useResource(() => api.sources(), []);
  return useMemo(() => {
    const order = toolOrder(sources.data?.sources ?? []);
    const map = assignToolColors(order);
    return { order, colorOf: (id) => map.get(id) ?? OTHER_COLOR };
  }, [sources.data]);
}

/**
 * 大数字缩写，跟随「设置 → 数字单位」：英文 K/M/B 与中文 万/亿 两套。
 * 订阅 TokenFormat 上下文，切换后所在组件会重渲染。
 *
 * @returns {(value: number) => string}
 */
export function useFormatTokens() {
  const tokenFormat = useContext(TokenFormatContext);
  return (value) => formatTokenCount(value, { unitSystem: tokenFormat?.unitSystem ?? "chinese" });
}

/**
 * 金额：服务端给十进制字符串（USD）。
 *
 * 显示按 2 位小数并带千分位；极小值保留 4 位，免得显示成 0.00。
 * 带币种时按内置折算率换算（见 lib/currency），title 里保留 USD 原值。
 * 值为 null 时按价格状态说明原因，绝不显示 0。
 *
 * @param {{ value: string|number|null|undefined, state?: string, digits?: number, mono?: boolean }} props
 *   `digits` 显式指定小数位；不传时按上一条规则自动取。`mono={false}` 时沿用所在位置的字体，
 *   只保留等宽数字（首页的衬线大数字、正文句子里用）。
 */
export function Money({ value, state, digits: fixedDigits, mono = true }) {
  const currency = useCurrency();

  if (value === null || value === undefined || value === "") {
    const label = state === "aggregate" ? "待核价" : state === "verified" ? "—" : "未定价";
    return <span className="text-ink-muted" title="该模型没有可用价格">{label}</span>;
  }

  const amount = Number(value);
  if (!Number.isFinite(amount)) {
    return <span className="text-ink-muted" title={String(value)}>—</span>;
  }

  const code = currency?.currency ?? "USD";
  const rate = currency?.rate ?? 1;
  const converted = code === "USD" ? amount : amount * rate;
  const digits = typeof fixedDigits === "number"
    ? Math.max(0, Math.min(6, Math.floor(fixedDigits)))
    : converted > 0 && converted < 0.01 ? 4 : 2;
  return (
    <span className={mono ? "tabular" : "tabular-nums"} title={`$${value}`}>
      {formatUsdCurrency(value, { decimals: digits, currency: code, rate })}
    </span>
  );
}

/**
 * token 数：null 表示客户端没上报，与 0 不是一回事。
 *
 * @param {{ value: number|null|undefined, short?: boolean }} props
 */
export function Tokens({ value, short = false }) {
  const formatTokens = useFormatTokens();
  if (value === null || value === undefined) {
    return <span className="text-ink-muted" title="客户端没有上报该字段">—</span>;
  }
  return <span className="tabular">{short ? formatTokens(value) : value.toLocaleString("en-US")}</span>;
}

/**
 * 三态包装。加载给占位线，失败给可重试的错误块。
 *
 * @param {{ status: string, error: any, onRetry: () => void, rows?: number, children: any }} props
 */
/**
 * 有数据的重新加载只在顶部出一条进度条，内容不动；首次加载才铺骨架。
 *
 * @param {{ status: string, error?: any, onRetry?: () => void, rows?: number,
 *           refreshing?: boolean, children: React.ReactNode }} props
 */
export function AsyncBlock({ status, error, onRetry, rows = 3, refreshing = false, children }) {
  if (status === "loading") return <SkeletonLines rows={rows} />;
  if (status === "error") {
    const code = error instanceof ApiError ? error.code : "request_failed";
    const message = error?.message || "请求失败";
    return (
      <div className="flex items-start gap-2 rounded-panel bg-surface-0 px-3 py-2.5">
        <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-signal-danger" aria-hidden />
        <div className="min-w-0 flex-1">
          <p className="text-caption font-medium text-ink">加载失败（{code}）</p>
          <p className="mt-0.5 break-words text-caption text-ink-muted">{message}</p>
        </div>
        <Button variant="ghost" size="xs" onClick={onRetry}>重试</Button>
      </div>
    );
  }
  return (
    <>
      {refreshing ? (
        <div
          className="mb-2 h-[2px] overflow-hidden rounded-pill bg-[var(--lens-fill-hover)]"
          role="progressbar"
          aria-label="正在加载"
        >
          <i className="lens-progress block h-full w-1/3 rounded-pill bg-clay" />
        </div>
      ) : null}
      {children}
    </>
  );
}

/**
 * 页面骨架。定高外壳里，内容默认自己滚；需要整屏排布的页面传 `scroll={false}`
 * 并自己管理内部滚动。
 *
 * @param {{ children: React.ReactNode, scroll?: boolean }} props
 */
export function PageScroll({ children, scroll = true }) {
  return (
    <div className={scroll ? "h-full overflow-y-auto pr-1" : "flex h-full min-h-0 flex-col gap-3"}>
      {children}
    </div>
  );
}

/**
 * 相对时间：给「最后观测」这类高频刷新字段用。
 *
 * @param {{ iso: string|null|undefined }} props
 */
export function RelativeTime({ iso }) {
  if (!iso) return <span className="text-ink-muted">—</span>;
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return <span className="text-ink-muted">—</span>;
  const minutes = Math.round((Date.now() - then) / 60000);
  const text =
    minutes < 1 ? "刚刚" : minutes < 60 ? `${minutes} 分钟前` : minutes < 1440 ? `${Math.round(minutes / 60)} 小时前` : `${Math.round(minutes / 1440)} 天前`;
  return <span title={iso}>{text}</span>;
}
