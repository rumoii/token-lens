import { PRICE_VERSION } from '../../pricing/engine.js';
import { classifyPrice, findPrice, localProvider } from '../../pricing/catalog.js';
import { snapshotMeta } from './common.js';

/** 单价统一为 USD / 百万 token；不单独计价的分项为 null。 */
function pricesOf(perMTok) {
  return {
    input: perMTok.input ?? null,
    output: perMTok.output ?? null,
    cache_read: perMTok.cacheRead ?? null,
    cache_write_5m: perMTok.cacheWrite ?? null,
    cache_write_1h: perMTok.cacheWrite1h ?? null
  };
}

/**
 * 价格页：价表版本 + 每个出现过模型的价格状态。
 *
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @returns {Object}
 */
export function buildPricing(queries) {
  const marks = new Map();
  for (const { model, provider, mark, records, model_records } of queries.modelPriceMarks()) {
    if (!marks.has(model)) marks.set(model, { model, records: model_records, entries: new Map(), locals: new Map(), localRecords: 0 });
    const m = marks.get(model);
    m.entries.set(mark, (m.entries.get(mark) ?? 0) + records);
    const local = localProvider(provider);
    if (local) {
      m.locals.set(local, (m.locals.get(local) ?? 0) + records);
      m.localRecords += records;
    }
  }
  const models = [...marks.values()].map((m) => {
    const cls = classifyPrice(m.model);
    const local = m.localRecords === m.records;
    const price = local ? null : findPrice(m.model);
    const tod = price?.timeOfDay;
    const holidays = tod?.holidays ?? [];
    return {
      model: m.model,
      records: m.records,
      state: local ? 'local' : cls.state,
      billing: local ? 'local' : cls.billing,
      source_url: local ? null : cls.sourceUrl,
      note: local ? '本地提供方，金额按 0 计。' : cls.note,
      local_records: m.localRecords,
      local_providers: Object.fromEntries(m.locals),
      prices: local ? pricesOf({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0 }) : price ? pricesOf(price.perMTok) : null,
      tiers: price?.tiers?.map(tier => ({ above: tier.above, prices: pricesOf(tier.perMTok) })) ?? null,
      time_of_day: tod ? {
        utc_offset_minutes: tod.utcOffsetMinutes,
        peak: tod.peak.map(({ days, from, to }) => ({ days: [...days], from, to })),
        off_peak_prices: pricesOf(tod.offPeak),
        holidays_count: holidays.length,
        holidays_through: holidays.length ? [...holidays].sort().at(-1) : null
      } : null,
      price_marks: Object.fromEntries(m.entries)
    };
  });

  const byState = { verified: [], aggregate: [], unknown: [], local: [] };
  for (const m of models) byState[m.state].push(m.model);

  return {
    price_version: PRICE_VERSION,
    verified_at: models.length ? new Date().toISOString().slice(0, 10) : null,
    currency: 'USD',
    provisional: byState.aggregate.length > 0,
    models,
    counts: {
      verified: byState.verified.length,
      aggregate: byState.aggregate.length,
      unknown: byState.unknown.length,
      local: byState.local.length
    },
    snapshot: snapshotMeta()
  };
}

/**
 * @param {Object} options
 * @returns {Object}
 */
export function buildHealth(options) {
  return {
    ok: true,
    version: options.version,
    port: options.port,
    data_dir: options.dataDir,
    db: { path: options.ledgerPath, schema_version: options.schemaVersion }
  };
}
