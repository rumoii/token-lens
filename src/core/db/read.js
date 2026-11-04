/**
 * SQLite 的时间位移修饰符。偏移为 0 时返回 `null`（按 UTC 处理，不拼多余参数）。
 *
 * @param {number|null|undefined} offsetMinutes
 * @returns {string|null}
 */
function shiftModifier(offsetMinutes) {
  const minutes = Number(offsetMinutes);
  if (!Number.isFinite(minutes) || minutes === 0) return null;
  return `'${minutes > 0 ? '+' : ''}${minutes} minutes'`;
}

function pruneBoundary(day, offsetMinutes, extraDays) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return null;
  const localMidnight = Date.parse(`${day}T00:00:00.000Z`);
  const offset = Number(offsetMinutes);
  if (!Number.isFinite(localMidnight) || new Date(localMidnight).toISOString().slice(0, 10) !== day) return null;
  return new Date(localMidnight + (extraDays * 1440 - (Number.isFinite(offset) ? offset : 0)) * 60000).toISOString();
}

/**
 * 时间桶表达式。桶的边界和显示必须用同一个时区，否则「今天」会被切在错误的地方。
 *
 * @param {'day'|'month'|'hour'} granularity
 * @param {string|null} shift
 * @returns {string|undefined}
 */
function bucketExpr(granularity, shift, column = 'observed_at') {
  const extra = shift ? `, ${shift}` : '';
  return {
    day: `date(${column}${extra})`,
    month: `strftime('%Y-%m', ${column}${extra})`,
    hour: `strftime('%Y-%m-%dT%H:00:00', ${column}${extra})`
  }[granularity];
}

/**
 * 能落进时间桶的记录：逐次事件，或开始与最后活动落在同一个桶里的累计快照。
 * 跨桶的累计快照不知道用量怎么分布，留给 `unallocated`。
 *
 * @param {'day'|'month'|'hour'} granularity
 * @param {string|null} shift
 * @returns {{ inBucket: string, unallocated: string }}
 */
function bucketable(granularity, shift) {
  const sameBucket = `(ended_at IS NOT NULL AND ${bucketExpr(granularity, shift)} = ${bucketExpr(granularity, shift, 'ended_at')})`;
  return {
    inBucket: `(kind = 'event' OR (kind = 'cumulative' AND ${sameBucket}))`,
    unallocated: `(kind = 'cumulative' AND NOT ${sameBucket})`
  };
}

/** 查询共享同一连接，不负责连接关闭或事务写入。 */
export class LedgerQueries {
  #db;
  #pruneEstimates = new Map();
  #pruneEstimateVersion;

  /** @param {import('node:sqlite').DatabaseSync} db */
  constructor(db) {
    this.#db = db;
  }

  dataVersion() {
    return Number(this.#db.prepare('PRAGMA data_version').get().data_version);
  }

  pruneEstimateKeys() {
    return [...this.#pruneEstimates.keys()];
  }

  #useObservedIndex(pruneFrom, pruneTo) {
    const dataVersion = this.dataVersion();
    if (this.#pruneEstimateVersion !== dataVersion) {
      this.#pruneEstimates.clear();
      this.#pruneEstimateVersion = dataVersion;
    }
    const key = JSON.stringify([pruneFrom, pruneTo, dataVersion]);
    const cached = this.#pruneEstimates.get(key);
    if (cached !== undefined) return cached;

    const where = [];
    const params = [];
    if (pruneFrom) { where.push('observed_at >= ?'); params.push(pruneFrom); }
    if (pruneTo) { where.push('observed_at < ?'); params.push(pruneTo); }
    const rangeCount = Number(this.#db.prepare(
      `SELECT count(*) AS count FROM usage_records WHERE ${where.join(' AND ')}`
    ).get(...params).count);
    const totalCount = Number(this.#db.prepare('SELECT count(*) AS count FROM usage_records').get().count);
    const useIndex = rangeCount <= totalCount * 0.25;
    this.#pruneEstimates.set(key, useIndex);
    return useIndex;
  }

  /**
   * 流式读取已定价记录，供定价引擎核对并累计分项；不重新写入金额。
   * 与聚合查询共用 active、日期、时区和维度过滤。
   * @param {Object} [filter]
   * @returns {Generator<Object>}
   */
  *costRows(filter = {}) {
    const { clause, params } = this.#where(filter, { extra: 'cost_micros IS NOT NULL' });
    yield* this.#db.prepare(`
      SELECT source, model, provider, project_key, price_version, cost_micros, kind, observed_at, ended_at,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             cache_write_5m_tokens, cache_write_1h_tokens
      FROM usage_records WHERE ${clause}
    `).iterate(...params);
  }

  /**
   * 旧账行数，用于对账。
   *
   * @returns {number}
   */
  legacyCount() {
    const row = this.#db.prepare('SELECT count(*) AS c FROM legacy_records').get();
    return Number(row?.c || 0);
  }

  /**
   * 原始用量汇总。未知 token 不参与求和，用 `*_known` 计数区分「未知」与「零」。
   *
   * @param {Object} [filter]
   * @returns {Object}
   */
  totals(filter = {}) {
    // 与其余查询共用 #where：同一套日期切窗（含时区偏移）与维度过滤，
    // 否则「分组之和 == 总额」这条硬不变量会被两个日期语义拆碎。
    const { clause, params } = this.#where(filter);
    const row = this.#db.prepare(`
      SELECT
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN input_tokens IS NULL THEN 1 ELSE 0 END) AS input_unknown,
        sum(CASE WHEN output_tokens IS NULL THEN 1 ELSE 0 END) AS output_unknown,
        sum(cache_read_tokens IS NULL) AS cache_read_unknown,
        sum(cache_write_tokens IS NULL) AS cache_write_unknown,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records WHERE ${clause}
    `).get(...params);

    const grossParts = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];
    const recordCount = Number(row?.record_count || 0);

    // 没有任何记录时，0 才是真值；有记录但字段缺失才是未知
    if (recordCount === 0) {
      return {
        record_count: 0,
        gross_tokens: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        input_unknown: 0,
        output_unknown: 0,
        cache_read_unknown: 0,
        cache_write_unknown: 0,
        unpriced_records: 0,
        cost_micros: 0
      };
    }

    const gross = grossParts.reduce((s, f) => s + Number(row?.[f] || 0), 0);

    return {
      record_count: recordCount,
      gross_tokens: gross,
      input_tokens: row?.input_tokens ?? null,
      output_tokens: row?.output_tokens ?? null,
      cache_read_tokens: row?.cache_read_tokens ?? null,
      cache_write_tokens: row?.cache_write_tokens ?? null,
      input_unknown: Number(row?.input_unknown || 0),
      output_unknown: Number(row?.output_unknown || 0),
      cache_read_unknown: Number(row?.cache_read_unknown || 0),
      cache_write_unknown: Number(row?.cache_write_unknown || 0),
      unpriced_records: Number(row?.unpriced_records || 0),
      cost_micros: row?.cost_micros === null || row?.cost_micros === undefined
        ? null
        : Number(row.cost_micros)
    };
  }

  /**
   * 按维度分组。分组之和必须等于 `totals()`，这是接口层的硬不变量。
   *
   * @param {'model'|'source'|'project'} by
   * @param {Object} [filter]
   * @returns {Array<Object>}
   */
  breakdown(by, filter = {}) {
    const column = { model: 'model', source: 'source', project: 'project_key' }[by];
    if (!column) throw new Error(`未知的 breakdown 维度：${by}`);

    const { clause, params } = this.#where(filter);
    const rows = this.#db.prepare(`
      SELECT
        ${column} AS bucket,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records
      WHERE ${clause}
      GROUP BY ${column}
      ORDER BY cost_micros DESC, record_count DESC
    `).all(...params);

    return rows.map((r) => this.#shapeTotals(r, { bucket: r.bucket }));
  }

  /**
   * 时间序列。累计快照不带逐次分布：开始与最后活动在同一个桶里的计入该桶，
   * 其余只在 `unallocated` 出现。
   *
   * @param {'day'|'month'|'hour'} granularity
   * @param {Object} [filter]
   * @returns {{ points: Array<Object>, unallocated: Object|null }}
   */
  timeseries(granularity, filter = {}) {
    const expr = bucketExpr(granularity, shiftModifier(filter.offsetMinutes));
    if (!expr) throw new Error(`未知的时间粒度：${granularity}`);

    const split = bucketable(granularity, shiftModifier(filter.offsetMinutes));
    const { clause, params } = this.#where(filter, { extra: split.inBucket });
    const rows = this.#db.prepare(`
      SELECT
        ${expr} AS bucket,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records
      WHERE ${clause}
      GROUP BY bucket
      ORDER BY bucket ASC
    `).all(...params);

    const cumulative = this.#where(filter, { extra: split.unallocated });
    const unallocatedRow = this.#db.prepare(`
      SELECT count(*) AS record_count,
        sum(input_tokens) AS input_tokens, sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens, sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records WHERE ${cumulative.clause}
    `).get(...cumulative.params);

    const unallocated = Number(unallocatedRow?.record_count || 0) > 0
      ? { ...this.#shapeTotals(unallocatedRow), reason: 'cumulative_without_time_distribution' }
      : null;

    return {
      points: rows.map((r) => this.#shapeTotals(r, { bucket: r.bucket })),
      unallocated
    };
  }

  /**
   * 组装 WHERE 子句，`kindOverride` 用于把累计型记录分流。
   *
   * @param {Object} filter
   * @param {{ kind?: string, extra?: string }} [options] `extra` 是不带参数的 SQL 条件
   * @returns {{ clause: string, params: any[] }}
   */
  #where(filter = {}, options = {}) {
    const { from = '', to = '', source = null, model = null, project = null, session = null } = filter;
    const shift = shiftModifier(filter.offsetMinutes);
    const dayExpr = shift ? `date(observed_at, ${shift})` : 'date(observed_at)';
    const where = ['+active = 1'];
    const params = [];
    if (options.kind) { where.push('kind = ?'); params.push(options.kind); }
    if (options.extra) where.push(options.extra);
    const pruneFrom = from ? pruneBoundary(from, filter.offsetMinutes, -1) : null;
    const pruneTo = to ? pruneBoundary(to, filter.offsetMinutes, 2) : null;
    const observed = (pruneFrom || pruneTo) && !this.#useObservedIndex(pruneFrom, pruneTo)
      ? '+observed_at'
      : 'observed_at';
    if (pruneFrom) { where.push(`${observed} >= ?`); params.push(pruneFrom); }
    if (pruneTo) { where.push(`${observed} < ?`); params.push(pruneTo); }
    if (from) { where.push(`${dayExpr} >= ?`); params.push(from); }
    if (to) { where.push(`${dayExpr} <= ?`); params.push(to); }
    if (source) { where.push('source = ?'); params.push(source); }
    if (model) { where.push('model = ?'); params.push(model); }
    if (project) { where.push('project_key = ?'); params.push(project); }
    if (session) { where.push('session_id = ?'); params.push(session); }
    return { clause: where.join(' AND '), params };
  }

  /**
   * 把一行聚合结果转成对外形状。
   *
   * 两种「没有数」要区分：
   * - 没有任何记录 → 0（确实没发生过，不是未知）
   * - 有记录但字段为 NULL → null（发生过，但客户端没报）
   *
   * @param {Object} row
   * @param {Object} [extra]
   * @returns {Object}
   */
  #shapeTotals(row, extra = {}) {
    const recordCount = Number(row?.record_count || 0);
    const gross = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']
      .reduce((s, f) => s + Number(row?.[f] || 0), 0);

    if (recordCount === 0) {
      return {
        ...extra,
        record_count: 0,
        gross_tokens: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        unpriced_records: 0,
        cost_micros: 0
      };
    }

    return {
      ...extra,
      record_count: recordCount,
      gross_tokens: gross,
      input_tokens: row?.input_tokens ?? null,
      output_tokens: row?.output_tokens ?? null,
      cache_read_tokens: row?.cache_read_tokens ?? null,
      cache_write_tokens: row?.cache_write_tokens ?? null,
      unpriced_records: Number(row?.unpriced_records || 0),
      cost_micros: row?.cost_micros === null || row?.cost_micros === undefined
        ? null
        : Number(row.cost_micros)
    };
  }

  /**
   * 时间 × 维度的二维聚合，供明细矩阵使用。
   *
   * 与 `timeseries` 同口径：跨桶的累计快照无法归入时间桶，单独放进 `unallocated`，
   * 因此 `rows` 之和 + `unallocated` 才等于总额。
   *
   * @param {'day'|'month'|'hour'} granularity
   * @param {'model'|'source'|'project'} groupBy
   * @param {Object} [filter]
   * @returns {{ rows: Array<Object>, unallocated: Object|null }}
   */
  timeseriesGrouped(granularity, groupBy, filter = {}) {
    const expr = bucketExpr(granularity, shiftModifier(filter.offsetMinutes));
    const column = { model: 'model', source: 'source', project: 'project_key' }[groupBy];
    if (!expr) throw new Error(`未知的时间粒度：${granularity}`);
    if (!column) throw new Error(`未知的分组维度：${groupBy}`);

    const split = bucketable(granularity, shiftModifier(filter.offsetMinutes));
    const { clause, params } = this.#where(filter, { extra: split.inBucket });
    const rows = this.#db.prepare(`
      SELECT
        ${expr} AS bucket,
        ${column} AS grp,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records
      WHERE ${clause}
      GROUP BY bucket, grp
      ORDER BY bucket ASC
    `).all(...params);

    const cumulative = this.#where(filter, { extra: split.unallocated });
    const unallocatedRow = this.#db.prepare(`
      SELECT count(*) AS record_count,
        sum(input_tokens) AS input_tokens, sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens, sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records WHERE ${cumulative.clause}
    `).get(...cumulative.params);

    const unallocated = Number(unallocatedRow?.record_count || 0) > 0
      ? { ...this.#shapeTotals(unallocatedRow), reason: 'cumulative_without_time_distribution' }
      : null;

    return {
      rows: rows.map((r) => this.#shapeTotals(r, { bucket: r.bucket, group: r.grp })),
      unallocated
    };
  }

  /**
   * 头部指标需要的活跃度统计：会话数、事件条数、缓存占比、时间跨度。
   *
   * @param {Object} [filter]
   * @returns {{ sessions: number, turns: number, input_tokens: number,
   *             cache_read_tokens: number, first_seen: string|null, last_seen: string|null }}
   */
  activity(filter = {}) {
    const { clause, params } = this.#where(filter);
    const row = this.#db.prepare(`
      SELECT
        count(DISTINCT session_id) AS sessions,
        sum(CASE WHEN kind = 'event' THEN 1 ELSE 0 END) AS turns,
        sum(coalesce(input_tokens, 0)) AS input_tokens,
        sum(coalesce(cache_read_tokens, 0)) AS cache_read_tokens,
        min(observed_at) AS first_seen,
        max(coalesce(ended_at, observed_at)) AS last_seen
      FROM usage_records WHERE ${clause}
    `).get(...params);

    return {
      sessions: Number(row?.sessions || 0),
      turns: Number(row?.turns || 0),
      input_tokens: Number(row?.input_tokens || 0),
      cache_read_tokens: Number(row?.cache_read_tokens || 0),
      first_seen: row?.first_seen || null,
      last_seen: row?.last_seen || null
    };
  }

  /**
   * 两维嵌套分组，供「来源 → 模型」这类树形结构使用。
   *
   * 上层合计由下层逐项相加得出，因此天然不会重复累加。
   *
   * @param {'source'|'model'|'project'} outerBy
   * @param {'source'|'model'|'project'} innerBy
   * @param {Object} [filter]
   * @returns {Array<Object>}
   */
  grouped(outerBy, innerBy, filter = {}) {
    const cols = { source: 'source', model: 'model', project: 'project_key' };
    const outer = cols[outerBy];
    const inner = cols[innerBy];
    if (!outer) throw new Error(`未知的外层维度：${outerBy}`);
    if (!inner) throw new Error(`未知的内层维度：${innerBy}`);

    const { clause, params } = this.#where(filter);
    return this.#db.prepare(`
      SELECT
        ${outer} AS outer_key,
        ${inner} AS inner_key,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records
      WHERE ${clause}
      GROUP BY outer_key, inner_key
      ORDER BY cost_micros DESC
    `).all(...params).map((r) => this.#shapeTotals(r, {
      outer_key: r.outer_key,
      inner_key: r.inner_key
    }));
  }

  /**
   * 按模型列出用量与计价状态，供价格页与分布表标注。
   *
   * @returns {Array<{ model: string|null, records: number, unpriced_records: number }>}
   */
  modelStatus() {
    return this.#db.prepare(`
      SELECT model,
             count(*) AS records,
             sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records
      FROM usage_records
      WHERE active = 1
      GROUP BY model
      ORDER BY records DESC
    `).all().map((r) => ({
      model: r.model,
      records: Number(r.records || 0),
      unpriced_records: Number(r.unpriced_records || 0)
    }));
  }

  /**
   * 活跃记录按模型、提供方与计价标记分组；首个分号前的来源不参与分组。
   * @returns {Array<{ model: string|null, provider: string|null, mark: string, records: number, model_records: number }>}
   */
  modelPriceMarks() {
    return this.#db.prepare(`
      SELECT model, provider,
             CASE WHEN instr(price_source, ';') > 0
               THEN substr(price_source, instr(price_source, ';') + 1)
               ELSE '' END AS mark,
             count(*) AS records,
             sum(count(*)) OVER (PARTITION BY model) AS model_records
      FROM usage_records
      WHERE active = 1
      GROUP BY model, mark, provider
      ORDER BY model_records DESC, model, mark, provider
    `).all().map((r) => ({
      model: r.model, provider: r.provider, mark: r.mark, records: Number(r.records || 0), model_records: Number(r.model_records || 0)
    }));
  }

  /**
   * 已登记的价格版本列表（新到旧）。
   *
   * @returns {string[]}
   */
  priceVersions() {
    return this.#db.prepare(
      'SELECT version FROM pricing_snapshot ORDER BY created_at DESC'
    ).all().map((r) => r.version);
  }

  /**
   * 会话列表。`next_cursor` 对客户端不透明，内部是偏移量编码。
   *
   * @param {Object} [options]
   * @param {number} [options.limit]
   * @param {string|null} [options.cursor]
   * @param {Object} [options.filter]
   * @returns {{ items: Array<Object>, next_cursor: string|null }}
   */
  sessions(options = {}) {
    const limit = Math.min(Math.max(Number(options.limit) || 50, 1), 200);
    const offset = decodeCursor(options.cursor);
    const { clause, params } = this.#where(options.filter || {});

    const rows = this.#db.prepare(`
      SELECT
        source, session_id,
        max(project_key) AS project_key,
        count(DISTINCT project_key) AS project_key_variants,
        min(observed_at) AS started_at,
        max(coalesce(ended_at, observed_at)) AS last_seen_at,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records
      WHERE ${clause} AND session_id IS NOT NULL
      GROUP BY source, session_id
      ORDER BY last_seen_at DESC, session_id ASC
      LIMIT ? OFFSET ?
    `).all(...params, limit + 1, offset);

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    return {
      items: page.map((r) => ({
        ...this.#shapeTotals(r),
        source: r.source,
        session_id: r.session_id,
        // 与 sessionDetail 同一条规则：跨多个项目时不替用户挑一个
        project_key: Number(r.project_key_variants || 0) === 1 ? r.project_key : null,
        started_at: r.started_at,
        last_seen_at: r.last_seen_at
      })),
      next_cursor: hasMore ? encodeCursor(offset + limit) : null
    };
  }

  /**
   * 单个会话的明细：汇总、按模型、按时间。
   *
   * 会话身份是 `(source, session_id)` 一对，两个都必须给——不同来源可能撞 session_id。
   * 时间线只统计事件型记录：累计型是会话快照，没有连续分布，`kinds` 告诉调用方它占多少。
   * 会话跨多个项目时 `project_key` 返回 `null`，不替用户挑一个。
   *
   * @param {{ source: string, sessionId: string, granularity?: 'hour'|'day' }} options
   * @returns {{ summary: Object, models: Object[], timeline: Object[],
   *             kinds: { event: number, cumulative: number } }|null}
   */
  sessionDetail(options = {}) {
    const { source, sessionId, granularity = 'hour', offsetMinutes = null } = options;
    if (!source || !sessionId) throw new Error('会话详情必须同时给出 source 与 session_id');

    const expr = bucketExpr(granularity, shiftModifier(offsetMinutes));
    if (!expr) throw new Error(`未知的时间粒度：${granularity}`);

    const { clause, params } = this.#where({ source, session: sessionId, offsetMinutes });

    const row = this.#db.prepare(`
      SELECT
        min(observed_at) AS started_at,
        max(coalesce(ended_at, observed_at)) AS last_seen_at,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros,
        max(project_key) AS project_key,
        count(DISTINCT project_key) AS project_variants,
        sum(CASE WHEN kind = 'event' THEN 1 ELSE 0 END) AS event_records,
        sum(CASE WHEN kind = 'cumulative' THEN 1 ELSE 0 END) AS cumulative_records
      FROM usage_records WHERE ${clause}
    `).get(...params);

    if (!row || Number(row.record_count || 0) === 0) return null;

    const summary = this.#shapeTotals(row, {
      source,
      session_id: sessionId,
      started_at: row.started_at,
      last_seen_at: row.last_seen_at,
      project_key: Number(row.project_variants || 0) === 1 ? row.project_key : null
    });

    const modelRows = this.#db.prepare(`
      SELECT model,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records WHERE ${clause}
      GROUP BY model
      ORDER BY record_count DESC
    `).all(...params);

    const eventScope = this.#where({ source, session: sessionId, offsetMinutes }, { kind: 'event' });
    const timeline = this.#db.prepare(`
      SELECT ${expr} AS bucket,
        count(*) AS record_count,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_write_tokens) AS cache_write_tokens,
        sum(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END) AS unpriced_records,
        sum(cost_micros) AS cost_micros
      FROM usage_records WHERE ${eventScope.clause}
      GROUP BY bucket
      ORDER BY bucket ASC
    `).all(...eventScope.params);

    return {
      summary,
      models: modelRows.map((r) => this.#shapeTotals(r, { model: r.model })),
      timeline: timeline.map((r) => this.#shapeTotals(r, { bucket: r.bucket })),
      kinds: {
        event: Number(row.event_records || 0),
        cumulative: Number(row.cumulative_records || 0)
      }
    };
  }

  /**
   * 按来源汇总状态，供 `/api/v1/sources` 使用。
   *
   * @returns {Array<Object>}
   */
  sourceStatus() {
    return this.#db.prepare(`
      SELECT source,
        count(*) AS record_count,
        sum(CASE WHEN kind = 'cumulative' THEN 1 ELSE 0 END) AS cumulative_records,
        min(observed_at) AS first_observed_at,
        max(coalesce(ended_at, observed_at)) AS last_observed_at
      FROM usage_records
      WHERE active = 1
      GROUP BY source
      ORDER BY source ASC
    `).all().map((r) => ({
      source: r.source,
      records: Number(r.record_count || 0),
      cumulative_records: Number(r.cumulative_records || 0),
      first_observed_at: r.first_observed_at,
      last_observed_at: r.last_observed_at
    }));
  }

  /**
   * 账本自检：按来源数出可疑的活跃记录，供 `/api/v1/sources` 使用。
   *
   * - 时间越界：开始或结束时间晚于 `now`，或开始早于 2023-01-01；
   * - 单条请求过大：逐条请求的 gross 超过 1 亿。累计快照是整场会话的总数，不在此列；
   * - 缺模型：不计价；
   * - 同一会话混用逐条请求与累计快照：会重复计数。
   *
   * @param {{ now: string }} options `now` 为 ISO 8601 UTC，与 `observed_at` 同格式，可直接按字符串比较
   * @returns {Map<string, { time_out_of_range: number, huge_requests: number, null_model: number, mixed_kind_sessions: number }>}
   */
  sourceChecks({ now }) {
    const checks = new Map();
    const rows = this.#db.prepare(`
      SELECT source,
        sum(CASE WHEN observed_at > ? OR ended_at > ? OR observed_at < '2023-01-01' THEN 1 ELSE 0 END) AS time_out_of_range,
        sum(CASE WHEN kind = 'event' AND coalesce(input_tokens, 0) + coalesce(output_tokens, 0)
          + coalesce(cache_read_tokens, 0) + coalesce(cache_write_tokens, 0) > 100000000 THEN 1 ELSE 0 END) AS huge_requests,
        sum(CASE WHEN model IS NULL THEN 1 ELSE 0 END) AS null_model
      FROM usage_records
      WHERE active = 1
      GROUP BY source
    `).all(now, now);
    for (const r of rows) {
      checks.set(r.source, {
        time_out_of_range: Number(r.time_out_of_range || 0),
        huge_requests: Number(r.huge_requests || 0),
        null_model: Number(r.null_model || 0),
        mixed_kind_sessions: 0
      });
    }
    const mixed = this.#db.prepare(`
      SELECT source, count(*) AS sessions FROM (
        SELECT source, session_id FROM usage_records
        WHERE active = 1 AND session_id IS NOT NULL
        GROUP BY source, session_id HAVING count(DISTINCT kind) > 1
      ) GROUP BY source
    `).all();
    for (const r of mixed) checks.get(r.source).mixed_kind_sessions = Number(r.sessions || 0);
    return checks;
  }

  /**
   * 活跃记录按来源与出处文件分组的条数。`source_file` 为 NULL 的是 schema v4 之前写入、此后再没被重读的行。
   *
   * @returns {Array<{ source: string, source_file: string|null, records: number }>}
   */
  sourceFiles() {
    return this.#db.prepare(`
      SELECT source, source_file, count(*) AS record_count
      FROM usage_records
      WHERE active = 1
      GROUP BY source, source_file
    `).all().map((r) => ({ source: r.source, source_file: r.source_file, records: Number(r.record_count || 0) }));
  }

  /**
   * 最近一次采集运行。`notes` 存的是异常字符串数组，解析失败时原样当一条异常。
   *
   * @returns {{ id: number, status: string, started_at: number|null, finished_at: number|null,
   *             attempted: number, inserted: number, updated: number, unchanged: number,
   *             rejected: number, counts: Object|null, anomalies: string[] }|null}
   */
  lastRun() {
    const row = this.#db.prepare(`
      SELECT id, status, started_at, finished_at, attempted, inserted, updated, unchanged, rejected, notes, counts
      FROM ingest_runs ORDER BY id DESC LIMIT 1
    `).get();
    if (!row) return null;

    let anomalies = [];
    if (row.notes) {
      try {
        const parsed = JSON.parse(row.notes);
        anomalies = Array.isArray(parsed) ? parsed.map(String) : [String(row.notes)];
      } catch {
        anomalies = [String(row.notes)];
      }
    }

    // v4 起按类计数；v3 及更早的运行没有这一列，给 null
    let counts = null;
    if (row.counts) {
      try {
        const parsed = JSON.parse(row.counts);
        counts = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
      } catch {
        counts = null;
      }
    }

    return {
      id: Number(row.id),
      status: String(row.status || 'unknown'),
      started_at: row.started_at == null ? null : Number(row.started_at),
      finished_at: row.finished_at == null ? null : Number(row.finished_at),
      attempted: Number(row.attempted || 0),
      inserted: Number(row.inserted || 0),
      updated: Number(row.updated || 0),
      unchanged: Number(row.unchanged || 0),
      rejected: Number(row.rejected || 0),
      counts,
      anomalies
    };
  }
}

/**
 * @param {string|null} cursor
 * @returns {number}
 */
function decodeCursor(cursor) {
  if (!cursor) return 0;
  try {
    const n = Number(Buffer.from(String(cursor), 'base64').toString('utf8'));
    return Number.isInteger(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

/**
 * @param {number} offset
 * @returns {string}
 */
function encodeCursor(offset) {
  return Buffer.from(String(offset), 'utf8').toString('base64');
}
