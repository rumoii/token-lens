import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerQueries } from '../../src/core/db/read.js';
import { costOf, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { findPrice } from '../../src/core/pricing/catalog.js';
import { buildPricing } from '../../src/core/api/v1/pricing.js';
import { createRouter } from '../../src/core/api/router.js';

const row = (model, fields = {}) => ({
  source: 'codex', record_key: model, session_id: 's', model,
  observed_at: '2026-10-26T02:00:00Z', kind: 'event',
  input_tokens: 1000, output_tokens: 100, cache_read_tokens: 0, cache_write_tokens: 0,
  ...fields
});

function seed(t, rows) {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch(rows, { priceOf: costOf });
  return ledger;
}

test('价格接口：分档和别名保留基础价，五项高档价格不舍入', (t) => {
  const ledger = seed(t, [row('gpt-6-1-sol'), row('claude-haiku-5-5')]);
  const models = new Map(buildPricing(ledger.read).models.map(m => [m.model, m]));
  const sol = models.get('gpt-6-1-sol');
  assert.deepEqual(sol.tiers, [{ above: 272000, prices: {
    input: 4, output: 15, cache_read: 0.2, cache_write_5m: 5, cache_write_1h: null
  } }]);
  assert.deepEqual(sol.prices, {
    input: 2, output: 10, cache_read: 0.1, cache_write_5m: 2.5, cache_write_1h: null
  });
  assert.equal(sol.time_of_day, null);
  assert.deepEqual(models.get('claude-haiku-5-5').tiers, [{ above: 100000, prices: {
    input: 0.5, output: 2.5, cache_read: 0.05, cache_write_5m: 0.625, cache_write_1h: 1
  } }]);
});

test('价格接口：峰谷时区、星期、分钟区间、低谷单价与节假日范围', (t) => {
  const ledger = seed(t, [row('deepseek-flash')]);
  const [model] = buildPricing(ledger.read).models;
  assert.equal(model.tiers, null);
  assert.deepEqual(model.prices, {
    input: 0.3, output: 1.2, cache_read: 0.006, cache_write_5m: null, cache_write_1h: null
  });
  assert.deepEqual(model.time_of_day, {
    utc_offset_minutes: 480,
    peak: [{ days: [1, 2, 3, 4, 5], from: 540, to: 720 }, { days: [1, 2, 3, 4, 5], from: 840, to: 1080 }],
    off_peak_prices: { input: 0.15, output: 0.6, cache_read: 0.003, cache_write_5m: null, cache_write_1h: null },
    holidays_count: 33,
    holidays_through: '2026-10-07'
  });
});

test('价格接口：无条件变价与未定价模型显式返回 null，缺模型仍独立统计', (t) => {
  const ledger = seed(t, [row('claude-opus-5-5'), row('unlisted-model'), row(null, { record_key: 'no-model' })]);
  const { models, counts } = buildPricing(ledger.read);
  assert.deepEqual(counts, { verified: 1, aggregate: 0, unknown: 2, local: 0 });
  for (const model of models) {
    assert.equal(model.tiers, null);
    assert.equal(model.time_of_day, null);
    assert.deepEqual(model.price_marks, { '': 1 });
    if (model.state === 'unknown') assert.equal(model.prices, null);
  }
});

test('价格接口：从实际计价记录统计所有档位和峰谷标记，分组之和等于 records', (t) => {
  const ledger = seed(t, [
    row('gpt-6.1-sol', { record_key: 'base' }),
    row('gpt-6.1-sol', { record_key: 'long', input_tokens: 272001 }),
    row('gpt-6.1-sol', { record_key: 'unknown', cache_write_tokens: null }),
    row('gpt-6.1-sol', { record_key: 'cumulative', kind: 'cumulative' }),
    row('deepseek-flash', { record_key: 'peak' }),
    row('deepseek-flash', { record_key: 'offpeak', observed_at: '2026-10-26T05:00:00Z' }),
    row('deepseek-flash', { record_key: 'blend', kind: 'cumulative',
      observed_at: '2026-10-26T00:00:00Z', ended_at: '2026-10-26T04:00:00Z' }),
    row('deepseek-flash', { record_key: 'weekly', kind: 'cumulative' })
  ]);
  const models = new Map(buildPricing(ledger.read).models.map(m => [m.model, m]));
  assert.deepEqual(models.get('gpt-6.1-sol').price_marks, {
    '': 1, 'tier:272000': 1, 'tier:unknown': 1, 'tier:cumulative': 1
  });
  assert.deepEqual(models.get('deepseek-flash').price_marks, {
    'tod:peak': 1, 'tod:offpeak': 1, 'tod:blend': 1, 'tod:weekly': 1
  });
  for (const model of models.values()) {
    assert.equal(Object.values(model.price_marks).reduce((sum, n) => sum + n, 0), model.records);
  }
});

test('标记查询：只计 active，合并不同来源前缀，无标记记空键，保留首个分号后的完整后缀', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  const insert = db.prepare(`INSERT INTO usage_records
    (record_key, content_hash, source, model, observed_at, kind, active, price_source)
    VALUES (?, 'fixture', 'codex', ?, '2026-10-26T02:00:00Z', 'event', ?, ?)`);
  const values = [
    ['a', 'gpt-6.1-sol', 1, 'verified:a;tier:272000'],
    ['b', 'gpt-6.1-sol', 1, 'normalized:b;tier:272000'],
    ['c', 'gpt-6.1-sol', 0, 'verified:a;tier:272000'],
    ['d', 'gpt-6.1-sol', 1, null],
    ['e', 'gpt-6.1-sol', 1, ''],
    ['f', 'gpt-6.1-sol', 1, 'verified:a'],
    ['g', 'gpt-6.1-sol', 1, 'verified:a;'],
    ['h', 'gpt-6.1-sol', 1, 'verified:a;tier:272000;tod:peak'],
    ['i', null, 1, null],
    ['j', 'inactive-only', 0, 'test;tod:peak'],
    ['k', 'gpt-6.1-sol', 1, 'test;__proto__']
  ];
  for (const value of values) insert.run(...value);
  const queries = new LedgerQueries(db);
  const before = db.prepare('SELECT * FROM usage_records ORDER BY id').all();
  const models = new Map(buildPricing(queries).models.map(m => [m.model, m]));
  assert.equal(models.has('inactive-only'), false);
  assert.deepEqual(models.get('gpt-6.1-sol').price_marks, JSON.parse(
    '{"":4,"tier:272000":2,"tier:272000;tod:peak":1,"__proto__":1}'
  ));
  assert.deepEqual(models.get(null).price_marks, { '': 1 });
  assert.equal(models.get('gpt-6.1-sol').records, 8);
  assert.deepEqual(db.prepare('SELECT * FROM usage_records ORDER BY id').all(), before, '读取不修改账本');
});

test('价格接口：节假日为空时截止日期为 null，非排序表仍取最晚日期', (t) => {
  const ledger = seed(t, [row('deepseek-flash')]);
  const tod = findPrice('deepseek-flash').timeOfDay;
  const holidays = tod.holidays;
  try {
    for (const dates of [[], ['2026-10-07', '2026-01-01', '2026-05-01']]) {
      tod.holidays = dates;
      const result = buildPricing(ledger.read).models[0].time_of_day;
      assert.equal(result?.holidays_count, dates.length);
      assert.equal(result?.holidays_through, dates.length ? '2026-10-07' : null);
    }
  } finally { tod.holidays = holidays; }
});

test('价格路由：JSON 新增字段可序列化，旧字段投影保持完整且相同', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-26T12:00:00Z') });
  const ledger = seed(t, [row('claude-opus-5-5')]);
  const router = createRouter({ queries: ledger.read,
    json: (_req, res, body, status = 200) => Object.assign(res, { body: JSON.parse(JSON.stringify(body)), status }) });
  const res = {};
  assert.equal(await router({ url: '/api/v1/pricing', method: 'GET' }, res, '/api/v1/pricing'), true);
  assert.equal(res.status, 200);
  const { tiers, time_of_day, price_marks, local_records, local_providers, ...oldModel } = res.body.models[0];
  assert.deepEqual({ tiers, time_of_day, price_marks }, { tiers: null, time_of_day: null, price_marks: { '': 1 } });
  assert.equal(local_records, 0);
  assert.deepEqual(local_providers, {});
  assert.deepEqual(oldModel, {
    model: 'claude-opus-5-5', records: 1, state: 'verified', billing: 'metered',
    source_url: 'https://platform.claude.com/docs/en/about-claude/pricing',
    note: findPrice('claude-opus-5-5').conditions,
    prices: { input: 4, output: 20, cache_read: 0.2, cache_write_5m: 5, cache_write_1h: 8 }
  });
  assert.deepEqual({ ...res.body, models: [] }, {
    price_version: PRICE_VERSION, verified_at: '2026-10-26', currency: 'USD', provisional: false,
    models: [], counts: { verified: 1, aggregate: 0, unknown: 0, local: 0 }, snapshot: res.body.snapshot
  });
});

test('价格接口：空账本不产生模型或标记', (t) => {
  const ledger = seed(t, []);
  const result = buildPricing(ledger.read);
  assert.deepEqual(result.models, []);
  assert.deepEqual(result.counts, { verified: 0, aggregate: 0, unknown: 0, local: 0 });
  assert.equal(result.verified_at, null);
});

test('价格接口：记录数与标记同一次聚合，避免两次读取间的新采集造成错配', (t) => {
  const ledger = seed(t, [row('gpt-6.1-sol')]);
  const modelStatus = ledger.read.modelStatus.bind(ledger.read);
  // 在独立的状态查询前插入一条，模拟两次 SELECT 之间的账本增长。
  t.mock.method(ledger.read, 'modelStatus', () => {
    ledger.write.ingestBatch([row('gpt-6.1-sol', { record_key: 'arriving' })], { priceOf: costOf });
    return modelStatus();
  });
  const [model] = buildPricing(ledger.read).models;
  assert.equal(Object.values(model.price_marks).reduce((sum, n) => sum + n, 0), model.records);
});
