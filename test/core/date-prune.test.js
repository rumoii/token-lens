import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerQueries } from '../../src/core/db/read.js';

const TOKEN_COLUMNS = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];

function shape(rows, extra = {}) {
  if (rows.length === 0) {
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
  const sum = (column) => rows.reduce((total, row) => total + (row[column] ?? 0), 0);
  const nullableSum = (column) => rows.some((row) => row[column] !== null) ? sum(column) : null;
  const result = {
    ...extra,
    record_count: rows.length,
    gross_tokens: TOKEN_COLUMNS.reduce((total, column) => total + sum(column), 0),
    input_tokens: nullableSum('input_tokens'),
    output_tokens: nullableSum('output_tokens'),
    cache_read_tokens: nullableSum('cache_read_tokens'),
    cache_write_tokens: nullableSum('cache_write_tokens'),
    unpriced_records: rows.filter((row) => row.cost_micros === null).length,
    cost_micros: rows.some((row) => row.cost_micros !== null) ? sum('cost_micros') : null
  };
  return result;
}

function localBucket(row, granularity, offsetMinutes) {
  const shifted = new Date(new Date(row.observed_at).getTime() + offsetMinutes * 60000).toISOString();
  if (granularity === 'day') return shifted.slice(0, 10);
  if (granularity === 'hour') return `${shifted.slice(0, 13)}:00:00`;
  return shifted.slice(0, 7);
}

class ReferenceQueries {
  constructor(db) {
    this.db = db;
  }

  rows(filter = {}, { priced = false } = {}) {
    const shift = filter.offsetMinutes ? `'${filter.offsetMinutes > 0 ? '+' : ''}${filter.offsetMinutes} minutes'` : null;
    const day = shift ? `date(observed_at, ${shift})` : 'date(observed_at)';
    const where = ['active = 1'];
    const params = [];
    if (priced) where.push('cost_micros IS NOT NULL');
    if (filter.from) { where.push(`${day} >= ?`); params.push(filter.from); }
    if (filter.to) { where.push(`${day} <= ?`); params.push(filter.to); }
    for (const [key, column] of [['source', 'source'], ['model', 'model'], ['project', 'project_key'], ['session', 'session_id']]) {
      if (filter[key]) { where.push(`${column} = ?`); params.push(filter[key]); }
    }
    return this.db.prepare(`SELECT * FROM usage_records WHERE ${where.join(' AND ')}`).all(...params);
  }

  totals(filter = {}) {
    const rows = this.rows(filter);
    const result = shape(rows);
    for (const column of TOKEN_COLUMNS) {
      result[`${column.replace('_tokens', '')}_unknown`] = rows.filter((row) => row[column] === null).length;
    }
    return result;
  }

  breakdown(by, filter = {}) {
    const column = { model: 'model', source: 'source', project: 'project_key' }[by];
    const groups = new Map();
    for (const row of this.rows(filter)) {
      const key = row[column];
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
    return [...groups.entries()].map(([bucket, rows]) => shape(rows, { bucket }))
      .sort((a, b) => (b.cost_micros ?? -1) - (a.cost_micros ?? -1) || b.record_count - a.record_count);
  }

  split(rows, granularity, offsetMinutes) {
    const allocated = [];
    const unallocated = [];
    for (const row of rows) {
      const same = row.ended_at !== null && localBucket(row, granularity, offsetMinutes) === localBucket({ ...row, observed_at: row.ended_at }, granularity, offsetMinutes);
      if (row.kind === 'event' || (row.kind === 'cumulative' && same)) allocated.push(row);
      else unallocated.push(row);
    }
    return { allocated, unallocated };
  }

  timeseries(granularity, filter = {}) {
    const { allocated, unallocated } = this.split(this.rows(filter), granularity, filter.offsetMinutes || 0);
    const groups = new Map();
    for (const row of allocated) {
      const bucket = localBucket(row, granularity, filter.offsetMinutes || 0);
      if (!groups.has(bucket)) groups.set(bucket, []);
      groups.get(bucket).push(row);
    }
    return {
      points: [...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([bucket, rows]) => shape(rows, { bucket })),
      unallocated: unallocated.length ? { ...shape(unallocated), reason: 'cumulative_without_time_distribution' } : null
    };
  }

  timeseriesGrouped(granularity, groupBy, filter = {}) {
    const column = { model: 'model', source: 'source', project: 'project_key' }[groupBy];
    const { allocated, unallocated } = this.split(this.rows(filter), granularity, filter.offsetMinutes || 0);
    const groups = new Map();
    for (const row of allocated) {
      const bucket = localBucket(row, granularity, filter.offsetMinutes || 0);
      const key = JSON.stringify([bucket, row[column] ?? null]);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
    return {
      rows: [...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([key, rows]) => {
        const [bucket, group] = JSON.parse(key);
        return shape(rows, { bucket, group });
      }),
      unallocated: unallocated.length ? { ...shape(unallocated), reason: 'cumulative_without_time_distribution' } : null
    };
  }

  grouped(outerBy, innerBy, filter = {}) {
    const columns = { source: 'source', model: 'model', project: 'project_key' };
    const outer = columns[outerBy];
    const inner = columns[innerBy];
    const groups = new Map();
    for (const row of this.rows(filter)) {
      const key = JSON.stringify([row[outer] ?? null, row[inner] ?? null]);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
    return [...groups.entries()].map(([key, rows]) => {
      const [outer_key, inner_key] = JSON.parse(key);
      return shape(rows, { outer_key, inner_key });
    }).sort((a, b) => (b.cost_micros ?? -1) - (a.cost_micros ?? -1));
  }

  activity(filter = {}) {
    const rows = this.rows(filter);
    return {
      sessions: new Set(rows.map((row) => row.session_id).filter((value) => value !== null)).size,
      turns: rows.filter((row) => row.kind === 'event').length,
      input_tokens: rows.reduce((sum, row) => sum + (row.input_tokens ?? 0), 0),
      cache_read_tokens: rows.reduce((sum, row) => sum + (row.cache_read_tokens ?? 0), 0),
      first_seen: rows.length ? rows.map((row) => row.observed_at).sort()[0] : null,
      last_seen: rows.length ? rows.map((row) => row.ended_at ?? row.observed_at).sort().at(-1) : null
    };
  }

  sessions({ filter = {}, limit = 50 } = {}) {
    const groups = new Map();
    for (const row of this.rows(filter).filter((row) => row.session_id !== null)) {
      const key = JSON.stringify([row.source, row.session_id]);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
    const items = [...groups.values()].map((rows) => {
      const projects = new Set(rows.map((row) => row.project_key));
      return {
        ...shape(rows),
        source: rows[0].source,
        session_id: rows[0].session_id,
        project_key: projects.size === 1 ? rows[0].project_key : null,
        started_at: rows.map((row) => row.observed_at).sort()[0],
        last_seen_at: rows.map((row) => row.ended_at ?? row.observed_at).sort().at(-1)
      };
    }).sort((a, b) => b.last_seen_at.localeCompare(a.last_seen_at) || a.session_id.localeCompare(b.session_id)).slice(0, limit);
    return { items, next_cursor: null };
  }

  *costRows(filter = {}) {
    for (const row of this.rows(filter, { priced: true })) {
      yield {
        source: row.source, model: row.model, provider: row.provider, project_key: row.project_key,
        price_version: row.price_version, cost_micros: row.cost_micros, kind: row.kind,
        observed_at: row.observed_at, ended_at: row.ended_at,
        input_tokens: row.input_tokens, output_tokens: row.output_tokens,
        cache_read_tokens: row.cache_read_tokens, cache_write_tokens: row.cache_write_tokens,
        cache_write_5m_tokens: row.cache_write_5m_tokens, cache_write_1h_tokens: row.cache_write_1h_tokens
      };
    }
  }
}

function seed(db, outsideRangeRows = 0) {
  const insert = db.prepare(`
    INSERT INTO usage_records (record_key, content_hash, source, session_id, project_key, model,
      observed_at, ended_at, kind, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
      active, price_version, cost_micros)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'test', ?)
  `);
  const rows = [
    ['boundary-before', '2024-01-01T15:59:59.999Z', null, 'event', 1],
    ['boundary-at', '2024-01-01T16:00:00.000Z', null, 'event', 1],
    ['without-millis', '2024-01-01T16:00:00Z', null, 'event', 1],
    ['next-day', '2024-01-02T15:59:59.999Z', null, 'event', 1],
    ['next-month', '2024-02-01T00:00:00.000Z', null, 'event', 1],
    ['previous-month', '2023-12-01T23:59:59.999Z', null, 'event', 1],
    ['cumulative-same', '2024-01-01T16:00:00.000Z', '2024-01-01T17:00:00Z', 'cumulative', 1],
    ['cumulative-cross', '2024-01-01T15:00:00.000Z', '2024-01-01T17:00:00.000Z', 'cumulative', 1],
    ['inactive', '2024-01-01T16:00:00.000Z', null, 'event', 0]
  ];
  rows.forEach(([key, observed, ended, kind, active], index) => insert.run(
    key, `hash-${key}`, index % 2 ? 'source-a' : 'source-b', `session-${index % 3}`, `project-${index % 2}`,
    `model-${index % 2}`, observed, ended, kind, index + 1, index + 2, index % 3 ? null : index + 3,
    index + 4, active, index * 100
  ));
  for (let index = 0; index < outsideRangeRows; index += 1) {
    insert.run(
      `outside-${index}`, `hash-outside-${index}`, 'source-a', `session-outside-${index}`, 'project-a',
      'model-a', '2025-01-01T00:00:00.000Z', null, 'event', 1, 2, 3, 4, 1, 100
    );
  }
}

function captureTotals(db, queries, filter) {
  const prepare = db.prepare.bind(db);
  let captured = null;
  db.prepare = (sql) => {
    const statement = prepare(sql);
    if (!sql.includes('count(*) AS record_count') || !sql.includes('input_unknown')) return statement;
    return new Proxy(statement, {
      get(target, property) {
        if (property === 'get') {
          return (...params) => {
            captured = { sql, params };
            return target.get(...params);
          };
        }
        const value = target[property];
        return typeof value === 'function' ? value.bind(target) : value;
      }
    });
  };
  try {
    queries.totals(filter);
  } finally {
    db.prepare = prepare;
  }
  assert.ok(captured);
  return captured;
}

test('日期剪枝与不剪枝的独立 SQL/JS 参照逐值一致', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  seed(db);
  const queries = new LedgerQueries(db);
  const reference = new ReferenceQueries(db);

  for (const offsetMinutes of [480, -300, 0, 345]) {
    for (const [from, to] of [
      ['2024-01-01', '2024-01-02'],
      ['2024-01-02', '2024-01-02'],
      ['2024-01-01', ''],
      ['', '2024-01-02']
    ]) {
      const filter = { from, to, offsetMinutes };
      const label = `offset=${offsetMinutes}, ${from}..${to}`;
      assert.deepEqual(queries.totals(filter), reference.totals(filter), `${label}: totals`);
      for (const granularity of ['day', 'hour']) {
        assert.deepEqual(queries.timeseries(granularity, filter), reference.timeseries(granularity, filter), `${label}: timeseries ${granularity}`);
        assert.deepEqual(queries.timeseriesGrouped(granularity, 'source', filter), reference.timeseriesGrouped(granularity, 'source', filter), `${label}: timeseriesGrouped ${granularity}`);
      }
      assert.deepEqual(queries.breakdown('source', filter), reference.breakdown('source', filter), `${label}: breakdown`);
      assert.deepEqual(queries.grouped('source', 'model', filter), reference.grouped('source', 'model', filter), `${label}: grouped`);
      assert.deepEqual(queries.activity(filter), reference.activity(filter), `${label}: activity`);
      assert.deepEqual(queries.sessions({ filter }), reference.sessions({ filter }), `${label}: sessions`);
      const actualCostRows = JSON.parse(JSON.stringify([...queries.costRows(filter)]));
      const expectedCostRows = [...reference.costRows(filter)];
      actualCostRows.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
      expectedCostRows.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
      assert.deepEqual(actualCostRows, expectedCostRows, `${label}: costRows`);
    }
  }
});

test('选择性范围使用 idx_usage_observed，并保留原精确日期条件和结果', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  seed(db, 40);
  const queries = new LedgerQueries(db);
  const reference = new ReferenceQueries(db);
  const filter = { from: '2024-01-01', to: '2024-01-02', offsetMinutes: 480 };
  const { sql, params } = captureTotals(db, queries, filter);
  assert.match(sql, /date\(observed_at, '\+480 minutes'\) >= \?/);
  assert.match(sql, /date\(observed_at, '\+480 minutes'\) <= \?/);
  assert.doesNotMatch(sql, /\+observed_at/);
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...params);
  assert.ok(plan.some((row) => String(row.detail).includes('idx_usage_observed') && String(row.detail).includes('observed_at>?') && String(row.detail).includes('observed_at<?')),
    JSON.stringify(plan));
  assert.deepEqual(queries.totals(filter), reference.totals(filter));
});

test('范围超过总行数 25% 时禁用时间索引并退回全表扫描', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  seed(db);
  const queries = new LedgerQueries(db);
  const reference = new ReferenceQueries(db);
  const filter = { from: '2024-01-01', to: '2024-01-02', offsetMinutes: 480 };
  const { sql, params } = captureTotals(db, queries, filter);
  assert.match(sql, /\+observed_at >= \?/);
  assert.match(sql, /\+observed_at < \?/);
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...params);
  assert.ok(plan.some((row) => String(row.detail) === 'SCAN usage_records'), JSON.stringify(plan));
  assert.deepEqual(queries.totals(filter), reference.totals(filter));
});

test('相同剪枝边界在同一 data_version 下只估计一次', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  seed(db, 40);
  const queries = new LedgerQueries(db);
  const filter = { from: '2024-01-01', to: '2024-01-02', offsetMinutes: 480 };
  const prepare = db.prepare.bind(db);
  let rangeCounts = 0;
  let totalCounts = 0;
  db.prepare = (sql) => {
    if (sql.includes('SELECT count(*) AS count FROM usage_records WHERE observed_at')) rangeCounts += 1;
    if (sql === 'SELECT count(*) AS count FROM usage_records') totalCounts += 1;
    return prepare(sql);
  };
  try {
    queries.totals(filter);
    queries.timeseries('day', filter);
    queries.breakdown('source', filter);
  } finally {
    db.prepare = prepare;
  }
  assert.equal(rangeCounts, 1);
  assert.equal(totalCounts, 1);
});

test('剪枝边界在本地日界换算成 UTC 后两侧各放宽一天', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  seed(db);
  const queries = new LedgerQueries(db);
  const { params } = captureTotals(db, queries, { from: '2024-01-01', to: '2024-01-01', offsetMinutes: 480 });
  assert.ok(params.includes('2023-12-30T16:00:00.000Z'), JSON.stringify(params));
  assert.ok(params.includes('2024-01-02T16:00:00.000Z'), JSON.stringify(params));
});

test('data_version 变化时清除旧版本的剪枝估计', (t) => {
  const { writer, queries } = openVersionedLedger(t);
  const filter = { from: '2024-01-01', to: '2024-01-02', offsetMinutes: 480 };
  queries.totals(filter);
  for (let index = 0; index < 3; index += 1) {
    const previousVersion = queries.dataVersion();
    commitVersionChange(writer, index);
    const currentVersion = queries.dataVersion();
    assert.notEqual(currentVersion, previousVersion);
    queries.totals(filter);
    const keys = queries.pruneEstimateKeys();
    assert.equal(keys.length, 1);
    assert.equal(JSON.parse(keys[0])[2], currentVersion);
  }
});

test('data_version 变化后相同范围重新计数', (t) => {
  const { db, writer, queries } = openVersionedLedger(t);
  const filter = { from: '2024-01-01', to: '2024-01-02', offsetMinutes: 480 };
  const prepare = db.prepare.bind(db);
  let rangeCounts = 0;
  db.prepare = (sql) => {
    if (sql.includes('SELECT count(*) AS count FROM usage_records WHERE observed_at')) rangeCounts += 1;
    return prepare(sql);
  };
  try {
    queries.totals(filter);
    for (let index = 0; index < 3; index += 1) {
      commitVersionChange(writer, index);
      queries.totals(filter);
    }
  } finally {
    db.prepare = prepare;
  }
  assert.equal(rangeCounts, 4);
});

function openVersionedLedger(t) {
  const dir = mkdtempSync(join(tmpdir(), 'tl-date-prune-version-'));
  const path = join(dir, 'ledger.db');
  const db = openLedger(path);
  seed(db, 40);
  const writer = new DatabaseSync(path);
  const queries = new LedgerQueries(db);
  t.after(() => {
    writer.close();
    db.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return { db, writer, queries };
}

function commitVersionChange(writer, index) {
  writer.exec('BEGIN');
  writer.prepare(`
    INSERT INTO usage_records (record_key, content_hash, source, session_id, project_key, model,
      observed_at, ended_at, kind, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
      active, price_version, cost_micros)
    VALUES (?, ?, 'source-a', ?, 'project-a', 'model-a', '2024-01-01T16:00:00.000Z', NULL,
      'event', 1, 2, 3, 4, 1, 'test', 100)
  `).run(`version-${index}`, `hash-version-${index}`, `session-version-${index}`);
  writer.exec('COMMIT');
}
