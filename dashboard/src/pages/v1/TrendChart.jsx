import React, { useState } from "react";
import { formatChineseNumber } from "../../lib/format";
import { bucketKeys } from "../../lib/period.js";
import { toolOf } from "../../lib/tools.js";
import { Money } from "./shared.jsx";

const ymd = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/** 现在所在的时段，比它晚的画成空槽。 */
export function nowBucketKey(granularity, now = new Date()) {
  if (granularity === "hour") return `${ymd(now)}T${String(now.getHours()).padStart(2, "0")}:00:00`;
  if (granularity === "month") return ymd(now).slice(0, 7);
  return ymd(now);
}

/**
 * 把 `/usage/matrix?by=source` 的行整理成图要的时段：每段按工具拆开，
 * 坐标轴上每个时段都补齐，没用的留空，还没到的标成 future。
 *
 * @param {Array<Object>|undefined} rows
 * @param {{ granularity: string, from: string|null, to: string|null }} axis
 * @param {Date} [now]
 */
export function buildBuckets(rows, axis, now = new Date()) {
  const nowKey = nowBucketKey(axis.granularity, now);
  const map = new Map();
  for (const row of rows ?? []) {
    const entry = map.get(row.bucket) || { bucket: row.bucket, by: new Map(), total: 0, cost: 0, future: false };
    entry.by.set(row.key, row.gross_tokens);
    entry.total += row.gross_tokens;
    entry.cost += Number(row.cost_usd || 0);
    map.set(row.bucket, entry);
  }
  for (const key of bucketKeys(axis.granularity, axis)) {
    if (!map.has(key)) map.set(key, { bucket: key, by: new Map(), total: 0, cost: null, future: key > nowKey });
  }
  return [...map.values()].sort((a, b) => String(a.bucket).localeCompare(String(b.bucket)));
}

export function niceCeil(max) {
  const e = Math.pow(10, Math.floor(Math.log10(Math.max(max, 1))));
  const f = Math.max(max, 1) / e;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * e;
}

/**
 * 堆叠柱状趋势。鼠标、键盘（聚焦后左右方向键）和触屏点按都能看单个时段；
 * 移出或失焦即收起提示。还没到的时段画成空槽。`weekdays` 时横轴写周几（本周用）。
 *
 * `order` 是固定的堆叠顺序（见 lib/tool-colors），`colorOf` 给每个工具的图表色。
 * 传了 `onPick` 时，点一根有数据的柱子（或聚焦后按回车）就把这个时段交给调用方，用来下钻；
 * `selected` 是已选中的时段，其余的柱子变淡。`grow` 让柱子从基线长出来（首页入场、换周期重长）；
 * `highlight` 是高亮的工具，其余工具的柱段变淡。
 */
export function TrendChart({
  buckets,
  order,
  granularity,
  colorOf,
  weekdays = false,
  onPick = null,
  selected = null,
  grow = false,
  highlight = null
}) {
  const [hover, setHover] = useState(null);
  const nice = niceCeil(Math.max(...buckets.map((b) => b.total), 1));
  const nonzero = buckets.filter((b) => b.total > 0);
  const avg = nonzero.reduce((sum, b) => sum + b.total, 0) / Math.max(1, nonzero.length);
  const gap = buckets.length > 20 ? "3px" : "8px";
  const todayKey = ymd(new Date());

  const label = (bucket, i) => {
    if (granularity === "hour") {
      return i % 3 === 0 ? `${Number(bucket.slice(11, 13))}时` : "";
    }
    if (granularity === "month") return `${Number(bucket.slice(5, 7))}月`;
    const d = new Date(`${bucket.slice(0, 10)}T00:00:00`);
    if (weekdays) return `周${"日一二三四五六"[d.getDay()]}`;
    if (buckets.length <= 10) return `${d.getMonth() + 1}/${d.getDate()}`;
    return i % 5 === 0 || i === buckets.length - 1 ? `${d.getMonth() + 1}/${d.getDate()}` : "";
  };

  const tipLabel = (bucket) => {
    if (granularity === "hour") {
      const day = bucket.slice(0, 10);
      const d = new Date(`${day}T00:00:00`);
      const prefix = day === todayKey ? "今天" : `${d.getMonth() + 1}月${d.getDate()}日`;
      return `${prefix} ${Number(bucket.slice(11, 13))}:00`;
    }
    if (granularity === "month") return `${Number(bucket.slice(0, 4))}年${Number(bucket.slice(5, 7))}月`;
    const d = new Date(`${bucket.slice(0, 10)}T00:00:00`);
    return `${d.getMonth() + 1}月${d.getDate()}日 周${"日一二三四五六"[d.getDay()]}`;
  };

  const lastFilled = (() => {
    for (let i = buckets.length - 1; i >= 0; i--) if (buckets[i].total > 0) return i;
    return Math.max(0, buckets.findIndex((b) => !b.future));
  })();

  const onKeyDown = (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
      if (event.key === "Escape") setHover(null);
      if (event.key === "Enter" && onPick && hover !== null && buckets[hover].total > 0) onPick(buckets[hover].bucket);
      return;
    }
    event.preventDefault();
    const step = event.key === "ArrowLeft" ? -1 : 1;
    setHover((current) => {
      const from = current ?? lastFilled;
      return Math.min(buckets.length - 1, Math.max(0, from + (current === null ? 0 : step)));
    });
  };

  const tip = hover !== null ? buckets[hover] : null;

  return (
    <div
      className="relative mt-1 h-[210px] rounded-md outline-none"
      tabIndex={0}
      role="group"
      aria-label={onPick ? "趋势图：聚焦后用左右方向键逐个查看时段，回车看这个时段的明细" : "趋势图：聚焦后用左右方向键逐个查看时段"}
      onMouseLeave={() => setHover(null)}
      onFocus={() => setHover((current) => current ?? lastFilled)}
      onBlur={() => setHover(null)}
      onKeyDown={onKeyDown}
    >
      {[0, 0.5, 1].map((f) => (
        <React.Fragment key={f}>
          <span
            className="absolute left-0 w-10 whitespace-nowrap text-right text-[11px] tabular-nums text-ink-faint"
            style={{ top: `calc(8px + (100% - 30px) * ${1 - f})`, transform: "translateY(-50%)" }}
          >
            {f ? formatChineseNumber(nice * f) : "0"}
          </span>
          <span
            className="absolute left-11 right-0 h-px bg-[var(--lens-line-soft)]"
            style={{ top: `calc(8px + (100% - 30px) * ${1 - f})` }}
          />
        </React.Fragment>
      ))}

      <div className="absolute bottom-[22px] left-11 right-0 top-2 flex items-end" style={{ gap }}>
        {buckets.map((bucket, i) => (
          <div
            key={bucket.bucket}
            className="flex h-full min-w-0 flex-1 cursor-default justify-center transition-opacity duration-fast ease-lens"
            style={{
              opacity: (hover !== null ? hover !== i : selected !== null && selected !== bucket.bucket) ? 0.35 : 1,
              cursor: onPick && bucket.total > 0 ? "pointer" : undefined
            }}
            onMouseEnter={() => setHover(i)}
            onClick={() => {
              if (onPick && bucket.total > 0) onPick(bucket.bucket);
              else setHover((current) => (current === i ? null : i));
            }}
            data-bucket={bucket.bucket}
          >
            <div
              className={`relative flex h-full w-full max-w-[48px] flex-col-reverse gap-px rounded-[5px] ${
                grow ? "lens-grow-y" : ""
              }`}
              style={
                grow
                  ? { animationDelay: `${230 + (i * Math.min(30, 360 / buckets.length)) / 0.7}ms` }
                  : undefined
              }
            >
              {bucket.future
                ? // 还没到的时段：贴底一道浅线，告诉人这里会有数据，但不占视觉
                  <i className="block h-[3px] w-full shrink-0 rounded-pill bg-[var(--lens-line-soft)]" />
                : order
                    .filter((id) => (bucket.by.get(id) || 0) > 0)
                    .map((id, idx, list) => (
                      <i
                        key={id}
                        className={`block w-full shrink-0 transition-[height,opacity] duration-[320ms] ease-lens motion-reduce:transition-none ${
                          idx === list.length - 1 ? "rounded-t-[5px]" : ""
                        }`}
                        style={{
                          height: `calc(${(bucket.by.get(id) / nice) * 100}% - 1px)`,
                          background: colorOf(id),
                          opacity: highlight && highlight !== id ? 0.35 : 1
                        }}
                      />
                    ))}
            </div>
          </div>
        ))}
      </div>

      {nonzero.length ? (
        <div
          className="pointer-events-none absolute left-11 right-0"
          style={{ top: `calc(8px + (100% - 30px) * ${1 - avg / nice})` }}
        >
          <div className="border-t-[1.5px] border-dashed border-ink-secondary opacity-55" />
          <span className="absolute right-0 top-[-20px] rounded bg-surface-2 px-1 text-[11px] text-ink-secondary">
            平均 {formatChineseNumber(avg)}
          </span>
        </div>
      ) : null}

      <div className="absolute bottom-0 left-11 right-0 flex text-[11px] text-ink-faint" style={{ gap }}>
        {buckets.map((bucket, i) => (
          <span
            key={bucket.bucket}
            className={`min-w-0 flex-1 whitespace-nowrap ${
              i === buckets.length - 1 && buckets.length > 10 ? "text-right" : "text-center"
            }`}
          >
            {label(bucket.bucket, i)}
          </span>
        ))}
      </div>

      {tip ? (
        // 定位层与柱子所在的绘图区同宽：左边让出 44px 的 y 轴
        <div className="pointer-events-none absolute bottom-[22px] left-11 right-0 top-0">
          <div
            role="tooltip"
            className="absolute top-0 z-10 min-w-[180px] rounded-[10px] bg-surface-3 p-2.5 text-[12.5px] shadow-pop"
            style={{
              left: `${((hover + 0.5) / buckets.length) * 100}%`,
              transform: hover + 1 > buckets.length / 2 ? "translateX(calc(-100% - 10px))" : "translateX(10px)"
            }}
          >
            <div className="flex items-center justify-between gap-3">
              <b>{tipLabel(tip.bucket)}</b>
              <span className="tabular-nums">
                {tip.future ? "还没到" : tip.total ? formatChineseNumber(tip.total) : "没有用量"}
              </span>
            </div>
            {order
              .filter((id) => (tip.by.get(id) || 0) > 0)
              .map((id) => (
                <div key={id} className="mt-1 flex items-center gap-2">
                  <i className="h-2 w-2 shrink-0 rounded-[3px]" style={{ background: colorOf(id) }} />
                  <span className="min-w-0 flex-1 text-ink-secondary">{toolOf(id).name}</span>
                  <span className="tabular-nums">{formatChineseNumber(tip.by.get(id))}</span>
                </div>
              ))}
            {tip.total ? (
              <div className="mt-1.5 flex items-center gap-2 text-ink-muted">
                <span className="min-w-0 flex-1">约值</span>
                <span className="tabular-nums">
                  <Money value={tip.cost} mono={false} />
                </span>
              </div>
            ) : null}
            {onPick && tip.total ? (
              <div className="mt-2 pt-1.5 text-[11.5px] text-ink-muted shadow-[inset_0_1px_0_var(--lens-line-soft)]">
                点一下看这{granularity === "hour" ? "个小时" : granularity === "month" ? "个月" : "天"}的明细
              </div>
            ) : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}
