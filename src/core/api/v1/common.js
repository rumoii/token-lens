import { formatMicros, PRICE_VERSION } from '../../pricing/engine.js';

/**
 * 时区名 → 相对 UTC 的分钟偏移。
 *
 * 取「当前时刻」的偏移，因此跨夏令时的历史会话会有偏差；对没有夏令时的时区（如 Asia/Shanghai）没有影响。
 * 认不出的时区名按 UTC 处理，不猜。
 *
 * @param {string|null|undefined} tz
 * @returns {number}
 */
export function offsetMinutesOf(tz) {
  const name = tz || Intl.DateTimeFormat().resolvedOptions().timeZone;
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: name,
      timeZoneName: 'longOffset'
    }).formatToParts(new Date());
    const raw = parts.find((part) => part.type === 'timeZoneName')?.value || '';
    const match = /GMT([+-])(\d{2}):(\d{2})/.exec(raw);
    if (!match) return 0;
    return (match[1] === '-' ? -1 : 1) * (Number(match[2]) * 60 + Number(match[3]));
  } catch {
    return 0;
  }
}

/**
 * @param {Object} [filters]
 * @param {Object} [extra]
 * @returns {Object}
 */
export function snapshotMeta(filters = {}, extra = {}) {
  return {
    generated_at: new Date().toISOString(),
    price_version: PRICE_VERSION,
    tz: filters.tz || Intl.DateTimeFormat().resolvedOptions().timeZone,
    filters,
    ...extra
  };
}

/**
 * @param {number|null} micros
 * @returns {string|null}
 */
export const money = (micros) => formatMicros(micros);

/**
 * @param {Object} row Ledger 的聚合行
 * @returns {Object}
 */
export function totalsShape(row) {
  return {
    gross_tokens: row.gross_tokens,
    input_tokens: row.input_tokens,
    output_tokens: row.output_tokens,
    cache_read_tokens: row.cache_read_tokens,
    cache_write_tokens: row.cache_write_tokens,
    cost_usd: money(row.cost_micros),
    unpriced_records: row.unpriced_records,
    record_count: row.record_count
  };
}

/** 用量与会话查询共用日期、时区和维度过滤。 */
export function queryFilter(params) {
  return {
    from: params.from || '', to: params.to || '',
    source: params.source || null, model: params.model || null, project: params.project || null,
    offsetMinutes: offsetMinutesOf(params.tz)
  };
}
