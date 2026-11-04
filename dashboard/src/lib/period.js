/**
 * 周期：URL 查询参数是唯一来源，侧栏与首页都从这里读。
 *
 * `?period=today|week|month|all|custom`，默认 `week`；custom 另带 `from`、`to`
 * （`YYYY-MM-DD`，按浏览器本地日期）。缺参或取值不认识时回落默认，不猜范围。
 */

export const PERIODS = ["today", "week", "month", "all", "custom"];

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

function ymd(date) {
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${m}-${d}`;
}

/**
 * @param {string} search location.search
 * @returns {{ period: string, from: string|null, to: string|null }}
 */
export function readPeriod(search) {
  const params = new URLSearchParams(search || "");
  const raw = params.get("period");
  const period = PERIODS.includes(raw) ? raw : "week";
  const from = params.get("from");
  const to = params.get("to");
  return {
    period,
    from: from && DAY_RE.test(from) ? from : null,
    to: to && DAY_RE.test(to) ? to : null
  };
}

/**
 * 本期范围。null 表示不带边界（「全部」）。
 * custom 缺 from/to 时不猜范围，按「全部」处理。
 *
 * @param {{ period: string, from: string|null, to: string|null }} p
 * @param {Date} [today] 测试注入固定日期
 * @returns {{ from: string|null, to: string|null }}
 */
export function periodRange(p, today = new Date()) {
  const { period, from, to } = p;
  if (period === "today") return { from: ymd(today), to: ymd(today) };
  if (period === "week") {
    const monday = new Date(today);
    monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));
    return { from: ymd(monday), to: ymd(today) };
  }
  if (period === "month") {
    return { from: ymd(new Date(today.getFullYear(), today.getMonth(), 1)), to: ymd(today) };
  }
  if (period === "custom") return from && to ? { from, to } : { from: null, to: null };
  return { from: null, to: null };
}

/**
 * 对比期与对比文案。「全部」「自定义」没有对比，返回 null。
 * 本月的对比到上月同日；上月没有这一天就到上月最后一天。
 *
 * @param {{ period: string }} p
 * @param {Date} [today]
 * @returns {{ from: string, to: string, label: string }|null}
 */
export function periodCompare(p, today = new Date()) {
  const { period } = p;
  if (period === "today") {
    const yesterday = new Date(today);
    yesterday.setDate(today.getDate() - 1);
    return { from: ymd(yesterday), to: ymd(yesterday), label: "昨天" };
  }
  if (period === "week") {
    const back = (today.getDay() + 6) % 7; // 今天距本周一的天数
    const prevMonday = new Date(today);
    prevMonday.setDate(today.getDate() - back - 7);
    const prevSame = new Date(prevMonday);
    prevSame.setDate(prevMonday.getDate() + back);
    return { from: ymd(prevMonday), to: ymd(prevSame), label: "上周" };
  }
  if (period === "month") {
    const prevFirst = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    const prevMonthDays = new Date(today.getFullYear(), today.getMonth(), 0).getDate();
    const sameDay = Math.min(today.getDate(), prevMonthDays);
    return {
      from: ymd(prevFirst),
      to: ymd(new Date(today.getFullYear(), today.getMonth() - 1, sameDay)),
      label: "上个月"
    };
  }
  return null;
}

/**
 * 趋势粒度：今天按小时，本周本月按日，全部按月；自定义看跨度。
 *
 * @param {{ period: string, from: string|null, to: string|null }} p
 * @returns {"hour"|"day"|"month"}
 */
export function periodGranularity(p) {
  const { period, from, to } = p;
  if (period === "today") return "hour";
  if (period === "week" || period === "month") return "day";
  if (period === "custom" && from && to) {
    const days = Math.round((Date.parse(to) - Date.parse(from)) / 86400000) + 1;
    return days <= 1 ? "hour" : days <= 62 ? "day" : "month";
  }
  return "month";
}

/**
 * 本期到今天为止的天数（活跃天数的分母）：今天 1，本周从周一算，本月从 1 号算，
 * 自定义按区间，全部从最早记录算。还没到的日子不算——周一看本周是 1 天，不是 7 天。
 *
 * @param {{ period: string, from: string|null, to: string|null }} p
 * @param {Date} [today]
 * @param {string|null} [firstSeen] 最早记录时间（ISO），只给「全部」用
 * @returns {number}
 */
export function periodElapsedDays(p, today = new Date(), firstSeen = null) {
  const { period, from, to } = p;
  const days = (a, b) => Math.round((startOfDay(b) - startOfDay(a)) / 86400000) + 1;
  if (period === "today") return 1;
  if (period === "week") return ((today.getDay() + 6) % 7) + 1;
  if (period === "month") return today.getDate();
  if (period === "custom" && from && to) {
    return Math.max(1, days(new Date(`${from}T00:00:00`), new Date(`${to}T00:00:00`)));
  }
  const first = firstSeen ? new Date(firstSeen) : null;
  if (!first || Number.isNaN(first.getTime())) return 1;
  return Math.max(1, days(first, today));
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** 「全部」跨度在这个天数以内时按天画，再长才按月。 */
const ALL_DAILY_LIMIT = 62;

/**
 * 趋势图的坐标轴：请求用的粒度，以及要画出来的完整时间槽范围。
 *
 * 本周固定周一到周日、本月固定整月：还没到的日子留空槽，图的宽度和刻度不随
 * 「今天是几号」变化。「全部」跨度短时按天，免得一个月只有一根柱子撑满整幅。
 *
 * @param {{ period: string, from: string|null, to: string|null }} p
 * @param {Date} [today]
 * @param {string|null} [firstSeen]
 * @returns {{ granularity: "hour"|"day"|"month", from: string|null, to: string|null }}
 */
export function periodAxis(p, today = new Date(), firstSeen = null) {
  const { period } = p;
  if (period === "today") return { granularity: "hour", from: ymd(today), to: ymd(today) };
  if (period === "week") {
    const monday = new Date(today);
    monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));
    const sunday = new Date(monday);
    sunday.setDate(monday.getDate() + 6);
    return { granularity: "day", from: ymd(monday), to: ymd(sunday) };
  }
  if (period === "month") {
    return {
      granularity: "day",
      from: ymd(new Date(today.getFullYear(), today.getMonth(), 1)),
      to: ymd(new Date(today.getFullYear(), today.getMonth() + 1, 0))
    };
  }
  if (period === "custom") {
    const range = periodRange(p, today);
    return { granularity: periodGranularity(p), ...range };
  }
  const first = firstSeen ? new Date(firstSeen) : null;
  if (!first || Number.isNaN(first.getTime())) return { granularity: "month", from: null, to: null };
  const span = Math.round((startOfDay(today) - startOfDay(first)) / 86400000) + 1;
  return { granularity: span <= ALL_DAILY_LIMIT ? "day" : "month", from: ymd(first), to: ymd(today) };
}

const STORE_KEY = "token-lens-period";

/**
 * 当前周期：URL 带了 `?period=` 就用 URL，否则用上次在首页选的，再没有就是本周。
 * 离开首页（URL 里没有 period）时侧栏也能沿用同一个周期。
 *
 * @param {string} search location.search
 * @returns {{ period: string, from: string|null, to: string|null }}
 */
export function currentPeriod(search) {
  if (new URLSearchParams(search || "").has("period")) return readPeriod(search);
  try {
    const stored = window.localStorage?.getItem(STORE_KEY);
    if (stored) return readPeriod(stored);
  } catch (_err) {
    // 读不到就用默认值
  }
  return readPeriod("");
}

/**
 * 周期对应的查询串（不带 ?），不写存储。
 *
 * @param {{ period: string, from?: string|null, to?: string|null }} p
 * @returns {string}
 */
export function periodQuery(p) {
  const query = new URLSearchParams({ period: p.period });
  if (p.period === "custom") {
    if (p.from) query.set("from", p.from);
    if (p.to) query.set("to", p.to);
  }
  return query.toString();
}

/**
 * 记住周期，供离开首页后的侧栏和下次回到首页时使用。
 *
 * @param {{ period: string, from?: string|null, to?: string|null }} p
 * @returns {string} 对应的查询串（不带 ?）
 */
export function rememberPeriod(p) {
  const text = periodQuery(p);
  try {
    window.localStorage?.setItem(STORE_KEY, text);
  } catch (_err) {
    // 存不下就只在本页生效
  }
  return text;
}

/**
 * 周期名，与原型的 pd.label 一致：今天 / 这周 / 这个月 / 全部 / 自定义。
 *
 * @param {string} period
 * @returns {string}
 */
export function periodLabel(period) {
  return { today: "今天", week: "这周", month: "这个月", all: "全部", custom: "自定义" }[period] || "这周";
}

/**
 * 该周期应有的全部时间桶，用来给趋势图补空槽。
 *
 * 只补有限区间：范围为 null（「全部」）时返回空数组，由调用方按已出现的桶绘制，
 * 免得凭空造出一段没有数据的时间轴。
 *
 * @param {"hour"|"day"|"month"} granularity
 * @param {{ from: string|null, to: string|null }} range
 * @param {Date} [today]
 * @returns {string[]} 与后端 time bucket 同格式：`YYYY-MM-DDTHH:00:00` / `YYYY-MM-DD` / `YYYY-MM`
 */
export function bucketKeys(granularity, range = { from: null, to: null }, today = new Date()) {
  const { from, to } = range || { from: null, to: null };

  if (granularity === "hour") {
    const day = from || ymd(today);
    return Array.from({ length: 24 }, (_, hour) => `${day}T${String(hour).padStart(2, "0")}:00:00`);
  }

  if (!from || !to) return [];

  if (granularity === "day") {
    const out = [];
    const cursor = new Date(`${from}T00:00:00`);
    const end = new Date(`${to}T00:00:00`);
    while (cursor <= end) {
      out.push(ymd(cursor));
      cursor.setDate(cursor.getDate() + 1);
    }
    return out;
  }

  if (granularity === "month") {
    const out = [];
    const start = new Date(`${from}T00:00:00`);
    const end = new Date(`${to}T00:00:00`);
    const cursor = new Date(start.getFullYear(), start.getMonth(), 1);
    while (cursor <= end) {
      out.push(`${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}`);
      cursor.setMonth(cursor.getMonth() + 1);
    }
    return out;
  }

  return [];
}
