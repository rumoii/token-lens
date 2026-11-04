import { findPrice, localProvider, PRICE_VERSION } from './catalog.js';

const MICROS_PER_USD = 1_000_000n;
const TOKENS_PER_MTOK = 1_000_000n;

/**
 * USD/1M tokens → micro-USD/1M tokens 的整数表示，避免全程浮点。
 *
 * 精度：1e-6 USD 每百万 token，即 $0.000000001 / 1M tokens 仍可表达。
 *
 * @param {number} perMTok
 * @returns {bigint}
 */
function perMTokToMicros(perMTok) {
  return BigInt(Math.round(perMTok * 1e6));
}

/**
 * 选这条记录适用的单价，以及写进 price_source 的档位标记。
 *
 * 长上下文分档只看单次请求：提示长度 = input + cache_read + cache_write，超过某档的
 * `above` 就整条按该档（取满足条件的最高档）。累计快照算不出单次提示长度，用基础档；
 * 某项未知且已知部分没超过最低阈值时无法判断，也用基础档。缺 kind 按 event，与账本入账一致。
 * 带峰谷分时的条目交给 timeOfDayRates（目录保证两者不同时出现）。
 *
 * @param {{ perMTok: Object, tiers: Array<{above:number, perMTok:Object}>|null }} price
 * @param {{ kind?: string, input_tokens?: number|null, cache_read_tokens?: number|null,
 *           cache_write_tokens?: number|null }} r
 * @returns {{ perMTok: Object, mark: string, blend?: { offPeak: Object, peakMs: bigint, offMs: bigint } }}
 */
function rates(price, r) {
  if (price.timeOfDay) return timeOfDayRates(price, r);
  if (!price.tiers) return { perMTok: price.perMTok, mark: '' };
  if ((r.kind ?? 'event') === 'cumulative') return { perMTok: price.perMTok, mark: ';tier:cumulative' };
  const prompt = [r.input_tokens, r.cache_read_tokens, r.cache_write_tokens];
  const known = prompt.reduce((sum, tokens) => sum + (tokens ?? 0), 0);
  const tier = price.tiers.findLast((t) => known > t.above);
  if (tier) return { perMTok: tier.perMTok, mark: `;tier:${tier.above}` };
  return { perMTok: price.perMTok, mark: prompt.some((tokens) => tokens == null) ? ';tier:unknown' : '' };
}

const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;

/**
 * 当地某一天（`dayStart` 为当地零点，按 UTC 毫秒数表示）里高峰时段与 [from, to) 的重叠毫秒数。
 * 节假日整天不算高峰。
 * @param {{ peak: Array<{days:number[], from:number, to:number}>, holidays: string[] }} tod
 * @param {number} dayStart
 * @param {number} from
 * @param {number} to
 * @returns {number}
 */
function peakOverlap(tod, dayStart, from, to) {
  const day = new Date(dayStart);
  if (tod.holidays.includes(day.toISOString().slice(0, 10))) return 0;
  let overlap = 0;
  for (const w of tod.peak) {
    if (!w.days.includes(day.getUTCDay())) continue;
    overlap += Math.max(0, Math.min(to, dayStart + w.to * MINUTE_MS) - Math.max(from, dayStart + w.from * MINUTE_MS));
  }
  return overlap;
}

/**
 * 峰谷分时的单价。时刻一律换算到条目的固定 UTC 偏移，不看机器时区。
 *
 * 逐条请求按 `observed_at` 取高峰价（基础 perMTok）或低谷价。累计快照按 [observed_at, ended_at)
 * 内高峰与低谷的毫秒数加权；结束时间未知、不晚于开始或时间无法解析时，用一周内高峰时长的固定占比
 * （不计节假日）。
 *
 * @param {{ perMTok: Object, timeOfDay: { utcOffsetMinutes:number, peak:Array<{days:number[], from:number, to:number}>,
 *           offPeak:Object, holidays:string[] } }} price
 * @param {{ kind?: string, observed_at?: string, ended_at?: string|null }} r
 * @returns {{ perMTok: Object, mark: string, blend?: { offPeak: Object, peakMs: bigint, offMs: bigint } }}
 */
function timeOfDayRates(price, r) {
  const tod = price.timeOfDay;
  const offset = tod.utcOffsetMinutes * MINUTE_MS;
  const start = Date.parse(r.observed_at ?? '');
  const weekly = () => {
    const peak = tod.peak.reduce((sum, w) => sum + (w.to - w.from) * MINUTE_MS * w.days.length, 0);
    return { perMTok: price.perMTok, mark: ';tod:weekly', blend: { offPeak: tod.offPeak, peakMs: BigInt(peak), offMs: BigInt(7 * DAY_MS - peak) } };
  };
  if ((r.kind ?? 'event') !== 'cumulative') {
    if (Number.isNaN(start)) return weekly();
    const local = start + offset;
    const dayStart = local - (((local % DAY_MS) + DAY_MS) % DAY_MS);
    return peakOverlap(tod, dayStart, local, local + 1) > 0
      ? { perMTok: price.perMTok, mark: ';tod:peak' }
      : { perMTok: tod.offPeak, mark: ';tod:offpeak' };
  }
  const end = r.ended_at == null ? NaN : Date.parse(r.ended_at);
  if (Number.isNaN(start) || Number.isNaN(end) || end <= start) return weekly();
  const from = start + offset;
  const to = end + offset;
  let peak = 0;
  for (let dayStart = from - (((from % DAY_MS) + DAY_MS) % DAY_MS); dayStart < to; dayStart += DAY_MS) {
    peak += peakOverlap(tod, dayStart, from, to);
  }
  return { perMTok: price.perMTok, mark: ';tod:blend', blend: { offPeak: tod.offPeak, peakMs: BigInt(peak), offMs: BigInt(to - from - peak) } };
}

/**
 * 单条记录的总额与四类分项，单位为整数 micro-USD（USD × 1e6）。
 *
 * 未知 token 不参与计算；模型无价返回 null。目录中某个分项费率为 null
 * 表示不单独计价，保持既有总额口径。分项逐条、逐档用整数除法截断后相加。
 *
 * 缓存写分档：`cache_write_5m_tokens` / `cache_write_1h_tokens` 有值时按档计价
 * （两档单价不同），两者都缺失时用合计乘 5 分钟档单价——与分档引入前的口径一致。
 *
 * @param {{model:string|null, provider?:string|null, kind?:string, observed_at?:string, ended_at?:string|null,
 *          input_tokens:number|null, output_tokens:number|null,
 *          cache_read_tokens:number|null, cache_write_tokens:number|null,
 *          cache_write_5m_tokens?:number|null, cache_write_1h_tokens?:number|null}} r
 * @returns {{ cost_micros: number|null, price_version: string, price_source: string|null,
 *   parts: { input: number, output: number, cache_read: number, cache_write: number }|null }}
 */
export function priceRecord(r) {
  const provider = localProvider(r.provider);
  if (provider) {
    return { cost_micros: 0, price_version: PRICE_VERSION, price_source: `local:${provider}`,
      parts: { input: 0, output: 0, cache_read: 0, cache_write: 0 } };
  }
  const price = findPrice(r.model);
  if (!price) {
    return { cost_micros: null, price_version: PRICE_VERSION, price_source: null, parts: null };
  }
  const { perMTok, mark, blend } = rates(price, r);

  /** @param {Object} table @param {string} key @returns {bigint} */
  const micros = (table, key) => {
    const rate = key === 'cacheWrite1h' ? (table.cacheWrite1h ?? table.cacheWrite) : table[key];
    return rate === null || rate === undefined ? 0n : perMTokToMicros(rate);
  };

  /**
   * 加权时：floor(tokens × (高峰单价 × 高峰时长 + 低谷单价 × 低谷时长) / (总时长 × 1e6))，全程整数。
   * @param {number|null|undefined} tokens
   * @param {string} key
   * @returns {bigint}
   */
  const part = (tokens, key) => {
    if (tokens === null || tokens === undefined) return 0n;
    if (!blend) return (BigInt(tokens) * micros(perMTok, key)) / TOKENS_PER_MTOK;
    const weighted = micros(perMTok, key) * blend.peakMs + micros(blend.offPeak, key) * blend.offMs;
    return (BigInt(tokens) * weighted) / ((blend.peakMs + blend.offMs) * TOKENS_PER_MTOK);
  };

  const parts = {
    input: part(r.input_tokens, 'input'),
    output: part(r.output_tokens, 'output'),
    cache_read: part(r.cache_read_tokens, 'cacheRead'),
    cache_write: 0n
  };

  const hasSplit = r.cache_write_5m_tokens != null || r.cache_write_1h_tokens != null;
  if (hasSplit) {
    parts.cache_write = part(r.cache_write_5m_tokens, 'cacheWrite') + part(r.cache_write_1h_tokens, 'cacheWrite1h');
  } else {
    parts.cache_write = part(r.cache_write_tokens, 'cacheWrite');
  }

  return {
    cost_micros: Number(Object.values(parts).reduce((sum, amount) => sum + amount, 0n)),
    price_version: PRICE_VERSION,
    price_source: `${price.tier || (price.provisional ? 'aggregate' : 'verified')}:${price.id}${mark}`,
    parts: Object.fromEntries(Object.entries(parts).map(([key, amount]) => [key, Number(amount)]))
  };
}

/**
 * 写入账本的价格元数据；与分项查询共用 priceRecord，保持原有返回形状。
 * @param {Parameters<typeof priceRecord>[0]} r
 * @returns {{ cost_micros: number|null, price_version: string, price_source: string|null }}
 */
export function costOf(r) {
  const { cost_micros, price_version, price_source } = priceRecord(r);
  return { cost_micros, price_version, price_source };
}

/**
 * micro-USD → 十进制字符串（USD）。
 *
 * @param {number|null} micros
 * @param {number} [scale] 小数位，默认 6
 * @returns {string|null}
 */
export function formatMicros(micros, scale = 6) {
  if (micros === null || micros === undefined) return null;
  const negative = micros < 0;
  const abs = BigInt(Math.abs(Math.round(micros)));
  const base = MICROS_PER_USD;

  const whole = abs / base;
  const frac = abs % base;
  const fracStr = frac.toString().padStart(6, '0').slice(0, scale);
  return `${negative ? '-' : ''}${whole}.${fracStr}`;
}

/**
 * 最大余数法把总额拆给各分项，保证显示分项之和等于显示总额。
 *
 * @param {number[]} values 各分项（micro-USD）
 * @param {number} totalValue 总额（micro-USD）
 * @param {number} [scale] 显示小数位
 * @returns {string[]} 与 values 同序的十进制字符串
 */
export function allocateDisplay(values, totalValue, scale = 6) {
  const step = Number(MICROS_PER_USD) / Math.pow(10, scale);

  const floors = values.map((v) => Math.floor(v / step));
  const totalFloor = Math.floor(totalValue / step);
  let remainder = totalFloor - floors.reduce((a, b) => a + b, 0);

  const order = values
    .map((v, i) => ({ i, rem: v / step - Math.floor(v / step) }))
    .sort((a, b) => (b.rem - a.rem) || (a.i - b.i));

  const result = floors.slice();
  let cursor = 0;
  while (remainder > 0 && order.length > 0) {
    result[order[cursor % order.length].i] += 1;
    remainder -= 1;
    cursor += 1;
  }

  return result.map((units) => {
    const micros = units * step;
    return formatMicros(micros, scale);
  });
}

export { PRICE_VERSION };
