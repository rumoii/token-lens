import { Fragment, useContext, useState } from "react";
import { ChevronRight, ExternalLink, RefreshCw } from "lucide-react";
import { api } from "../../lib/v1";
import { CURRENCY_CNY, CURRENCY_USD, DEFAULT_RATES } from "../../lib/currency";
import { formatChineseNumber } from "../../lib/format";
import { TOKEN_UNIT_SYSTEMS } from "../../lib/token-format.js";
import { useTheme } from "../../hooks/useTheme";
import { Segmented } from "../../ui/lens/Segmented.jsx";
import { EmptyState } from "../../ui/lens/EmptyState.jsx";
import { useCurrency } from "../../ui/foundation/CurrencyProvider.jsx";
import { TokenFormatContext } from "../../ui/foundation/TokenFormatProvider.jsx";
import { AsyncBlock, PageScroll, useResource } from "./shared.jsx";
import { Card, SecHead, useNarrow } from "./HomeParts.jsx";

/** 价格状态与接口一致；本地用量的金额为 0。 */
const STATE = {
  verified: ["已对照官方价", "和厂商的价格页逐项对过", "text-signal-ok bg-[color-mix(in_srgb,var(--lens-ok)_12%,transparent)]"],
  aggregate: ["估算价", "厂商没单独公布，或者还没核对，按同类模型估算", "text-signal-warn bg-[color-mix(in_srgb,var(--lens-warn)_14%,transparent)]"],
  unknown: ["查不到价格", "这些用量照常统计 token，但不计入金额", "text-signal-danger bg-[color-mix(in_srgb,var(--lens-danger)_12%,transparent)]"],
  local: ["本地", "本地提供方，金额按 0 计", "text-ink-secondary bg-[var(--lens-fill-hover)]"]
};

function StateBadge({ state }) {
  const [label, , tone] = STATE[state] || STATE.unknown;
  return <span className={`inline-flex h-5 items-center whitespace-nowrap rounded-pill px-[7px] text-[11.5px] font-medium ${tone}`}>{label}</span>;
}

/**
 * 单价。价目本身就是 USD / 百万 token，按原值输出，不四舍五入成两位——
 * 0.125 这类值舍入后会变成 0.13，读数就假了。
 */
function priceText(value) {
  if (value === null || value === undefined) return "—";
  return `$${Number(value)}`;
}

const recordText = (count) => Number(count ?? 0).toLocaleString("en-US");
const hasConditionalPrices = (model) => Boolean(model.tiers?.length || model.time_of_day);
const timeText = (minutes) => `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
const holidayText = (tod) => tod.holidays_through
  ? `节假日仅登记到 ${tod.holidays_through.slice(0, 4)} 年`
  : "尚未登记节假日";

function ConditionalPriceSummary({ model }) {
  if (!hasConditionalPrices(model)) return null;
  const marks = model.price_marks ?? {};
  const items = (model.tiers ?? []).map(tier =>
    `单次提示 > ${recordText(tier.above)} token · ${recordText(marks[`tier:${tier.above}`])} 条按长上下文计`
  );
  if (model.tiers?.length && marks["tier:unknown"]) items.push(`${recordText(marks["tier:unknown"])} 条提示长度不完整 · 基础档`);
  if (model.time_of_day) {
    items.push(`峰谷分时 · ${recordText(marks["tod:offpeak"])} 条低谷`,
      `${recordText(marks["tod:blend"])} 条区间加权`, `${recordText(marks["tod:weekly"])} 条周占比估算`, holidayText(model.time_of_day));
  }
  return <span className="mt-1 block whitespace-normal text-[12px] leading-relaxed text-ink-secondary">{items.join(" · ")}</span>;
}

function priceMarkLabel(mark) {
  const labels = {
    "": "未标记",
    "tier:unknown": "提示长度不完整 · 基础档",
    "tier:cumulative": "累计快照 · 基础档",
    "tod:peak": "高峰", "tod:offpeak": "低谷", "tod:blend": "区间加权", "tod:weekly": "周占比估算"
  };
  if (Object.hasOwn(labels, mark)) return labels[mark];
  return /^tier:\d+$/.test(mark) ? `长上下文（提示 > ${recordText(mark.slice(5))} token）` : mark;
}

function ConditionalPrices({ model }) {
  const tod = model.time_of_day;
  const rows = [
    { label: tod ? "高峰" : "基础档", prices: model.prices },
    ...(model.tiers ?? []).map(tier => ({ label: `提示 > ${recordText(tier.above)} token`, prices: tier.prices })),
    ...(tod ? [{ label: "低谷", prices: tod.off_peak_prices }] : [])
  ];
  const columns = [
    ["新输入", "input"], ["输出", "output"], ["读缓存", "cache_read"],
    ["写缓存（短时）", "cache_write_5m"],
    ["写缓存（存 1 小时）", "cache_write_1h"]
  ];
  const offset = Math.abs(tod?.utc_offset_minutes ?? 0);
  const zone = tod?.utc_offset_minutes === 480 ? "北京时间（UTC+8）"
    : `UTC${tod?.utc_offset_minutes < 0 ? "-" : "+"}${Math.floor(offset / 60)}${offset % 60 ? `:${String(offset % 60).padStart(2, "0")}` : ""}`;
  const days = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  return (
    <>
      <h3 className="m-0 text-[13px] font-medium text-ink">{[model.tiers?.length ? "长上下文分档" : null, tod ? "峰谷分时" : null].filter(Boolean).join(" · ")}</h3>
      <div className="mt-2 max-w-full overflow-x-auto" role="region" aria-label="条件价格表，可横向滚动" tabIndex={0}>
        <table className="w-full min-w-[520px] border-collapse text-[12.5px]" aria-label={`${model.model ?? "没写模型"} 条件价格`}>
          <caption className="pb-2 text-left text-ink-secondary">USD / 百万 token · — 表示不单独计价</caption>
          <thead>
            <tr className="text-ink-secondary">
              <th scope="col" className="border-b border-[var(--lens-line)] px-2 py-2 text-left font-normal">档位</th>
              {columns.map(([label, key]) => <th key={key} scope="col" className="border-b border-[var(--lens-line)] px-2 py-2 text-right font-normal">{label}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map(row => (
              <tr key={row.label}>
                <th scope="row" className="border-b border-[var(--lens-line)] px-2 py-2 text-left font-normal text-ink">{row.label}</th>
                {columns.map(([, key]) => <td key={key} className="border-b border-[var(--lens-line)] px-2 py-2 text-right tabular-nums text-ink">{priceText(row.prices?.[key])}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <dl className="mb-0 mt-3 flex flex-wrap gap-x-5 gap-y-1 text-[12.5px]">
        {Object.entries(model.price_marks ?? {}).map(([mark, count]) => (
          <div key={mark} className="flex gap-1">
            <dt className="text-ink-secondary">{priceMarkLabel(mark)}</dt>
            <dd className="m-0 font-medium tabular-nums text-ink">{recordText(count)} 条</dd>
          </div>
        ))}
      </dl>
      {model.tiers?.length ? (
        <p className="mb-0 mt-3 text-[12.5px] text-ink-secondary">
          提示长度含新输入、缓存读和缓存写；恰好等于门槛仍用较低档。累计快照用基础档。提示长度不完整且已知部分未超过门槛时，用基础档并标记。
        </p>
      ) : null}
      {tod ? (
        <div className="mt-3 text-[12.5px] text-ink-secondary">
          <p className="m-0">{zone}，以下时段为高峰，结束时刻不含在内：</p>
          <ul className="mb-1 mt-1 list-none p-0">
            {tod.peak.map((peak, index) => <li key={index}>{peak.days.map(day => days[day]).join("、")} {timeText(peak.from)}–{timeText(peak.to)}</li>)}
          </ul>
          <p className="m-0">其余时段与已登记节假日全天按低谷价；周末补班日按周末计。</p>
          <p className="mb-0 mt-1">{holidayText(tod)}{tod.holidays_through ? `（${recordText(tod.holidays_count)} 天，最晚 ${tod.holidays_through}）` : ""}；未登记年份仍按星期和时段判断。</p>
        </div>
      ) : null}
    </>
  );
}

function SettingRow({ title, hint, children }) {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-[18px] py-3.5 [&+&]:shadow-[inset_0_1px_0_var(--lens-line-soft)]">
      <div className="w-full shrink-0 md:w-[140px]">
        <b className="block text-[14px] font-medium text-ink">{title}</b>
        <span className="text-[12.5px] text-ink-muted">{hint}</span>
      </div>
      {children}
    </div>
  );
}

/**
 * 价格与设置：上面是「显示」（外观、数字单位、货币），下面是「价格」（逐模型价目），
 * 价格表版本、端口、数据目录收进最底部的「关于」。
 */
export function SettingsPage() {
  const narrow = useNarrow();
  const tokenFormat = useContext(TokenFormatContext);
  const currency = useCurrency();
  const { theme, setTheme } = useTheme();
  const pricing = useResource(() => api.pricing(), []);
  const usage = useResource(() => api.breakdown("source_model"), []);
  const health = useResource(() => api.health(), [], { ledger: false });
  const [expanded, setExpanded] = useState(null);
  const [aboutOpen, setAboutOpen] = useState(false);

  const models = pricing.data?.models || [];
  const counts = pricing.data?.counts;
  // 每个模型累计用了多少
  const byModel = new Map();
  for (const g of usage.data?.groups ?? []) {
    const entry = byModel.get(g.model ?? null) || { tokens: 0 };
    entry.tokens += g.gross_tokens;
    byModel.set(g.model ?? null, entry);
  }
  const unitSample = tokenFormat?.unitSystem === TOKEN_UNIT_SYSTEMS.CHINESE ? "18.2亿 token · 3700万 token" : "1.82B token · 37.0M token";
  const cny = currency?.rates?.CNY ?? DEFAULT_RATES.CNY;
  const rateWhen = currency?.fetchedAt
    ? new Date(currency.fetchedAt).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) + " 更新"
    : "内置汇率";

  const display = (
    <Card>
      <SecHead title="显示" />
      <div className="py-1.5">
        <SettingRow title="外观" hint="浅色、深色或跟着系统走">
          <Segmented
            ariaLabel="外观"
            value={theme}
            onChange={setTheme}
            options={[
              { value: "light", label: "浅色" },
              { value: "dark", label: "深色" },
              { value: "system", label: "跟随系统" }
            ]}
          />
        </SettingRow>
        <SettingRow title="数字单位" hint="大数字怎么缩写">
          <Segmented
            ariaLabel="数字单位"
            value={tokenFormat?.unitSystem ?? TOKEN_UNIT_SYSTEMS.ENGLISH}
            onChange={(value) => tokenFormat?.setUnitSystem(value)}
            options={[
              { value: TOKEN_UNIT_SYSTEMS.CHINESE, label: "万 / 亿" },
              { value: TOKEN_UNIT_SYSTEMS.ENGLISH, label: "K / M / B" }
            ]}
          />
          <span className="text-[12.5px] text-ink-muted">例：{unitSample}</span>
        </SettingRow>
        <SettingRow title="货币" hint="金额用什么显示">
          <Segmented
            ariaLabel="货币"
            value={currency?.currency ?? CURRENCY_USD}
            onChange={(value) => currency?.setCurrency(value)}
            options={[
              { value: CURRENCY_USD, label: "美元 $" },
              { value: CURRENCY_CNY, label: "人民币 ¥" }
            ]}
          />
          <span className="text-[12.5px] text-ink-muted">
            1 美元 ≈ {cny.toFixed(2)} 元 · {rateWhen}
          </span>
          <button
            type="button"
            onClick={() => currency?.refreshRates()}
            disabled={Boolean(currency?.refreshing)}
            className="inline-flex items-center gap-1 rounded-md px-1.5 py-1 text-[13px] text-ink-secondary transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink disabled:opacity-60"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${currency?.refreshing ? "animate-spin" : ""}`} aria-hidden />
            {currency?.refreshing ? "更新中…" : "更新汇率"}
          </button>
          {currency?.error ? <span className="text-[12px] text-signal-danger">{currency.error}</span> : null}
          <p className="m-0 w-full text-[12px] text-ink-muted">
            只换显示，账本里的金额不变。汇率只在点「更新汇率」时联网取一次，失败就保留现在的值。
          </p>
        </SettingRow>
      </div>
    </Card>
  );

  const priceLine = (model) => (
    <>
      {model.prices && model.prices.input != null ? (
        <span className="tabular-nums">
          输入 {priceText(model.prices.input)} · 输出 {priceText(model.prices.output)}
        </span>
      ) : (
        <span className="text-ink-muted">没有公开价</span>
      )}
      {model.local_records > 0 && model.state !== "local" ? (
        <span className="block text-caption text-ink-muted">其中 {recordText(model.local_records)} 条本地 · 金额按 0 计</span>
      ) : null}
    </>
  );
  const expandedBody = (model) => (
    <>
      {hasConditionalPrices(model) ? <ConditionalPrices model={model} /> : (
        <dl className="m-0 grid grid-cols-2 gap-x-[18px] gap-y-2.5 text-[12.5px] md:grid-cols-5">
          {[
            ["新输入", model.prices?.input],
            ["输出", model.prices?.output],
            ["读缓存", model.prices?.cache_read],
            ["写缓存（存 5 分钟）", model.prices?.cache_write_5m],
            ["写缓存（存 1 小时）", model.prices?.cache_write_1h]
          ].map(([label, value]) => (
            <div key={label}>
              <dt className="text-ink-muted">{label}</dt>
              <dd className="m-0 font-medium tabular-nums text-ink">{priceText(value)}</dd>
            </div>
          ))}
        </dl>
      )}
      <p className="mb-0 mt-2.5 text-[12.5px] text-ink-muted">
        {model.note || (model.state === "verified" ? "和厂商价格页逐项对过。" : STATE[model.state]?.[1])}
        {model.billing === "plan" ? " 用套餐时不按这个价扣费。" : ""}
        {model.source_url ? (
          <a
            href={model.source_url}
            target="_blank"
            rel="noreferrer"
            onClick={(event) => event.stopPropagation()}
            className="ml-1.5 inline-flex items-center gap-0.5 text-ink-secondary underline decoration-[var(--lens-line-strong)] underline-offset-2 hover:text-ink"
          >
            官方价格页 <ExternalLink className="h-3 w-3" aria-hidden />
          </a>
        ) : null}
      </p>
    </>
  );

  const priceTable = narrow ? (
    <ul className="m-0 flex list-none flex-col p-0">
      {models.map((model) => {
        const key = String(model.model);
        const open = expanded === key;
        return (
          <li key={key}>
            <button
              type="button"
              aria-expanded={open}
              onClick={() => setExpanded(open ? null : key)}
              className="-mx-2.5 block w-[calc(100%+20px)] rounded-xl px-2.5 py-3 text-left hover:bg-[var(--lens-fill-hover)]"
            >
              <span className="flex items-center justify-between gap-2">
                <span className="truncate font-medium text-ink">{model.model ?? "没写模型"}</span>
                <StateBadge state={model.state} />
              </span>
              <span className="mt-1 flex flex-wrap gap-3 text-[12.5px] text-ink-secondary">
                {priceLine(model)}
                <span>累计 {formatChineseNumber(byModel.get(model.model)?.tokens ?? 0)}</span>
                {model.billing === "plan" ? <span>套餐</span> : null}
              </span>
              <ConditionalPriceSummary model={model} />
            </button>
            {open ? <div className="mb-2 rounded-xl bg-[var(--lens-fill-hover)] p-3">{expandedBody(model)}</div> : null}
          </li>
        );
      })}
    </ul>
  ) : (
    <table className="w-full border-collapse text-[13px]">
      <thead>
        <tr className="text-left text-caption text-ink-muted">
          <th className="px-2.5 py-2 font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">模型</th>
          <th className="px-2.5 py-2 font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">每百万 token</th>
          <th className="px-2.5 py-2 font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">价格</th>
          <th className="px-2.5 py-2 text-right font-normal shadow-[inset_0_-1px_0_var(--lens-line)]">累计用量</th>
        </tr>
      </thead>
      <tbody>
        {models.map((model) => {
          const key = String(model.model);
          const open = expanded === key;
          const toggle = () => setExpanded(open ? null : key);
          return (
            <Fragment key={key}>
              <tr
                tabIndex={0}
                aria-expanded={open}
                onClick={toggle}
                onKeyDown={(event) => {
                  if (event.key !== "Enter" && event.key !== " ") return;
                  event.preventDefault();
                  toggle();
                }}
                className="cursor-pointer transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] focus-visible:bg-[var(--lens-fill-hover)]"
              >
                <td className="px-2.5 py-2.5 shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                  <div className="min-w-0">
                    <div className="font-medium text-ink">{model.model ?? "没写模型"}</div>
                    {model.billing === "plan" ? <div className="text-caption text-ink-muted">套餐</div> : null}
                  </div>
                </td>
                <td className="whitespace-nowrap px-2.5 py-2.5 shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                  {priceLine(model)}
                  <ConditionalPriceSummary model={model} />
                </td>
                <td className="px-2.5 py-2.5 shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                  <StateBadge state={model.state} />
                </td>
                <td className="whitespace-nowrap px-2.5 py-2.5 text-right tabular-nums text-ink-secondary shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
                  {formatChineseNumber(byModel.get(model.model)?.tokens ?? 0)}
                </td>
              </tr>
              {open ? (
                <tr>
                  <td colSpan={4} className="bg-[var(--lens-fill-hover)] px-2.5 py-3">
                    {expandedBody(model)}
                  </td>
                </tr>
              ) : null}
            </Fragment>
          );
        })}
      </tbody>
    </table>
  );

  const prices = (
    <Card>
      <SecHead
        title="价格"
        sub="金额是按各模型的公开价算出来的，用来比较和感知，不是你的账单。用套餐的话，实际花费通常更低。"
      />
      <div className="px-[18px] pb-[18px] pt-3">
        <AsyncBlock refreshing={usage.refreshing} status={usage.status} error={usage.error} onRetry={usage.reload} rows={1}>
        <AsyncBlock refreshing={pricing.refreshing} status={pricing.status} error={pricing.error} onRetry={pricing.reload} rows={5}>
          {models.length === 0 ? (
            <EmptyState title="还没有用到的模型" hint="同步之后，出现过的模型会逐条列在这里。" />
          ) : (
            <>
              <div className="mb-3 grid grid-cols-1 gap-3 md:grid-cols-4">
                {["verified", "aggregate", "unknown", "local"].map((state) => (
                  <div key={state} className="rounded-xl bg-[var(--lens-fill-hover)] px-3.5 py-3">
                    <StateBadge state={state} />
                    <div className="mt-1 text-[20px] font-semibold tabular-nums text-ink">{counts?.[state] ?? 0} 个模型</div>
                    <div className="text-caption text-ink-muted">{STATE[state][1]}</div>
                  </div>
                ))}
              </div>
              {priceTable}
              <p className="mb-0 mt-2.5 text-[12.5px] text-ink-muted">
                点一行看缓存价格和说明。价格表随软件内置，不联网也能用；联网更新价格还没有做。
              </p>
            </>
          )}
        </AsyncBlock>
        </AsyncBlock>
      </div>
    </Card>
  );

  const about = (
    <Card>
      <button
        type="button"
        aria-expanded={aboutOpen}
        onClick={() => setAboutOpen((v) => !v)}
        className="flex w-full items-center gap-1.5 px-[18px] py-3.5 text-left text-[13.5px] text-ink-secondary hover:text-ink"
      >
        <ChevronRight className={`h-3.5 w-3.5 transition-transform duration-fast ${aboutOpen ? "rotate-90" : ""}`} aria-hidden />
        关于这台电脑上的 Token Lens
      </button>
      {aboutOpen ? (
        <div className="px-[18px] pb-4">
          <AsyncBlock refreshing={health.refreshing} status={health.status} error={health.error} onRetry={health.reload} rows={2}>
            <dl className="m-0 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3.5 gap-y-1 text-[13px]">
              <dt className="text-ink-muted">版本</dt>
              <dd className="m-0 font-mono text-ink">{health.data?.version ?? "—"}</dd>
              <dt className="text-ink-muted">地址</dt>
              <dd className="m-0 text-ink">
                <span className="font-mono">http://127.0.0.1:{health.data?.port ?? "—"}</span>（只有这台电脑能打开）
              </dd>
              <dt className="text-ink-muted">数据目录</dt>
              <dd className="m-0 break-all font-mono text-ink">{health.data?.data_dir ?? "—"}</dd>
              <dt className="text-ink-muted">价格表版本</dt>
              <dd className="m-0 font-mono text-ink">{pricing.data?.price_version ?? "—"} · 内置</dd>
            </dl>
          </AsyncBlock>
        </div>
      ) : null}
    </Card>
  );

  return (
    <PageScroll>
      <div className="flex flex-col gap-3 md:gap-4">
        <div>
          <h1 className="font-serif text-[24px] font-medium leading-[1.25] tracking-[-0.01em] text-ink md:text-[28px]">价格与设置</h1>
          <p className="mt-1 text-[14px] text-ink-secondary">数字怎么显示，金额怎么算。</p>
        </div>
        {display}
        {prices}
        {about}
      </div>
    </PageScroll>
  );
}
