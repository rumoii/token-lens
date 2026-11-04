import { priceRecord, PRICE_VERSION } from '../../pricing/engine.js';
import { classifyPrice } from '../../pricing/catalog.js';
import { money, totalsShape, snapshotMeta, queryFilter } from './common.js';

/**
 * @param {Date} date
 * @returns {string}
 */
function isoDay(date) {
  return date.toISOString().slice(0, 10);
}

/**
 * 按记录核对价格版本与存储金额，再累加引擎给出的整数分项。
 * 一组有任何不匹配就不能声明它的分项；未定价记录不参与金额合计。
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {'model'|'source'|'project'|'source_model'} by
 * @param {Object} filter
 * @returns {Map<any, { parts: Object, invalid: boolean }>}
 */
function costByKindMap(queries, by, filter) {
  const map = new Map();
  const column = { model: 'model', source: 'source', project: 'project_key' }[by];
  for (const row of queries.costRows(filter)) {
    const key = by === 'source_model' ? JSON.stringify([row.source, row.model]) : row[column];
    let group = map.get(key);
    if (!group) {
      group = { parts: { input: 0, output: 0, cache_read: 0, cache_write: 0 }, invalid: false };
      map.set(key, group);
    }
    if (row.price_version !== PRICE_VERSION) {
      group.invalid = true;
      continue;
    }
    const price = priceRecord(row);
    if (price.cost_micros === null || price.cost_micros !== row.cost_micros) {
      group.invalid = true;
      continue;
    }
    for (const key of Object.keys(group.parts)) group.parts[key] += price.parts[key];
  }
  return map;
}

/** 分项仅在能逐行复核且与聚合总额相等时提供，不分配差额。 */
function costByKind(group, targetMicros) {
  if (!group || group.invalid || Object.values(group.parts).reduce((sum, part) => sum + part, 0) !== targetMicros) {
    return null;
  }
  return Object.fromEntries(Object.entries(group.parts).map(([key, value]) => [key, money(value)]));
}

/**
 * 时间 × 维度的明细矩阵。
 *
 * 累计型记录没有时间分布，单独返回，界面上必须与矩阵分开显示。
 *
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildMatrix(queries, params) {
  const by = params.by || 'model';
  const granularity = params.granularity || 'day';
  const filter = queryFilter(params);

  const { rows, unallocated } = queries.timeseriesGrouped(granularity, by, filter);

  return {
    granularity,
    by,
    rows: rows.map((row) => ({
      bucket: row.bucket,
      key: row.group ?? null,
      ...totalsShape(row)
    })),
    unallocated: unallocated
      ? {
          gross_tokens: unallocated.gross_tokens,
          cost_usd: money(unallocated.cost_micros),
          record_count: unallocated.record_count,
          reason: unallocated.reason
        }
      : null,
    snapshot: snapshotMeta(filter, { granularity, by })
  };
}

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildSummary(queries, params) {
  const filter = queryFilter(params);

  const totals = queries.totals(filter);

  const now = new Date();
  // 滚动窗口按本地日期算：包含今天在内共 7 个、30 个本地日
  const offset = filter.offsetMinutes || 0;
  const localNow = new Date(now.getTime() + offset * 60000);
  const sevenAgo = isoDay(new Date(localNow.getTime() - 6 * 86400000));
  const thirtyAgo = isoDay(new Date(localNow.getTime() - 29 * 86400000));

  const last7 = queries.totals({ ...filter, from: sevenAgo });
  const last30 = queries.totals({ ...filter, from: thirtyAgo });
  const activity = queries.activity(filter);

  const cacheDenominator = activity.input_tokens + activity.cache_read_tokens;

  return {
    totals: totalsShape(totals),
    activity: {
      sessions: activity.sessions,
      turns: activity.turns,
      cache_hit_ratio: cacheDenominator > 0
        ? Number((activity.cache_read_tokens / cacheDenominator).toFixed(4))
        : null,
      first_seen: activity.first_seen,
      last_seen: activity.last_seen,
      active_span_ms: activity.first_seen && activity.last_seen
        ? Math.max(0, new Date(activity.last_seen).getTime() - new Date(activity.first_seen).getTime())
        : null
    },
    rolling: {
      last_7d: { gross_tokens: last7.gross_tokens, cost_usd: money(last7.cost_micros) },
      last_30d: { gross_tokens: last30.gross_tokens, cost_usd: money(last30.cost_micros) }
    },
    snapshot: snapshotMeta(filter)
  };
}

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildTimeseries(queries, params) {
  const filter = queryFilter(params);
  const granularity = params.granularity || 'day';
  const { points, unallocated } = queries.timeseries(granularity, filter);

  return {
    granularity,
    points: points.map((p) => ({
      bucket: p.bucket,
      ...totalsShape(p)
    })),
    unallocated: unallocated
      ? {
          gross_tokens: unallocated.gross_tokens,
          cost_usd: money(unallocated.cost_micros),
          record_count: unallocated.record_count,
          reason: unallocated.reason
        }
      : null,
    snapshot: snapshotMeta(filter)
  };
}

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildBreakdown(queries, params) {
  const by = params.by || 'model';
  const filter = queryFilter(params);

  const totals = queries.totals(filter);

  // 「工具 × 模型」：首页一次拿全工具排行、每个工具的模型和缓存节省，不必逐个工具再请求
  if (by === 'source_model') {
    const kinds = costByKindMap(queries, by, filter);
    return {
      by,
      groups: queries.grouped('source', 'model', filter).map((g) => ({
        key: g.inner_key,
        source: g.outer_key,
        model: g.inner_key,
        ...totalsShape(g),
        price_state: classifyPrice(g.inner_key).state,
        cost_by_kind: costByKind(kinds.get(JSON.stringify([g.outer_key, g.inner_key])), g.cost_micros)
      })),
      totals: totalsShape(totals),
      snapshot: snapshotMeta(filter)
    };
  }

  const groups = queries.breakdown(by, filter);
  const kinds = costByKindMap(queries, by, filter);

  return {
    by,
    groups: groups.map((g) => ({
      key: g.bucket,
      ...totalsShape(g),
      // 按模型分组时标注价格状态，界面据此区分核验 / 聚合 / 套餐制 / 未知
      price_state: by === 'model' ? classifyPrice(g.bucket).state : null,
      cost_by_kind: costByKind(kinds.get(g.bucket), g.cost_micros)
    })),
    totals: totalsShape(totals),
    snapshot: snapshotMeta(filter)
  };
}

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildUnallocated(queries, params) {
  const filter = queryFilter(params);
  const { unallocated } = queries.timeseries('day', filter);

  return {
    unallocated: unallocated
      ? {
          gross_tokens: unallocated.gross_tokens,
          cost_usd: money(unallocated.cost_micros),
          record_count: unallocated.record_count,
          reason: unallocated.reason
        }
      : null,
    snapshot: snapshotMeta(filter)
  };
}
