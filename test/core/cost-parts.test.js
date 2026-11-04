import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf, priceRecord } from '../../src/core/pricing/engine.js';
import { buildBreakdown } from '../../src/core/api/v1/usage.js';
import { createRouter } from '../../src/core/api/router.js';

const kinds = (input, output, cacheRead, cacheWrite) => ({
  input, output, cache_read: cacheRead, cache_write: cacheWrite
});
const zero = kinds('0.000000', '0.000000', '0.000000', '0.000000');
const record = (overrides = {}) => ({
  source: 'claude', record_key: 'record', session_id: 'session', project_key: '/work/app',
  model: 'claude-opus-5-5', kind: 'event', observed_at: '2026-10-20T00:00:00Z',
  input_tokens: 10_000, output_tokens: 0, cache_read_tokens: 0,
  cache_write_tokens: 1000, cache_write_5m_tokens: 0, cache_write_1h_tokens: 1000,
  ...overrides
});

test('定价引擎：整数分项与原总额接口一致，保持逐项截断及返回字段', () => {
  const row = record({ input_tokens: 1, output_tokens: 1, cache_read_tokens: 3,
    cache_write_tokens: 1, cache_write_5m_tokens: null, cache_write_1h_tokens: null });
  const detail = priceRecord(row);
  assert.deepEqual(detail.parts, kinds(4, 20, 0, 5));
  assert.equal(detail.cost_micros, 29);
  assert.deepEqual(costOf(row), { cost_micros: 29, price_version: detail.price_version,
    price_source: 'verified:claude-opus-5-5' });
  assert.equal(priceRecord(record({ model: null })).parts, null);
  assert.equal(priceRecord(record({ model: null })).cost_micros, null);
});

function seed(t, rows, priceOf = costOf) {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch(rows, { priceOf });
  return ledger;
}

for (const by of ['model', 'source', 'project', 'source_model']) {
  test(`金额分项：${by} 的一小时写缓存不把差价转给输入`, (t) => {
    const ledger = seed(t, [record()]);
    const group = buildBreakdown(ledger.read, { by }).groups[0];
    assert.equal(group.cost_usd, '0.048000');
    assert.deepEqual(group.cost_by_kind, kinds('0.040000', '0.000000', '0.000000', '0.008000'));
  });
}

test('金额分项：两档缓存写各自计价，分档未知时保留原来的五分钟档口径', (t) => {
  const ledger = seed(t, [
    record({ record_key: 'split', project_key: 'split', cache_write_5m_tokens: 400, cache_write_1h_tokens: 600 }),
    record({ record_key: 'unsplit', project_key: 'unsplit', cache_write_5m_tokens: null, cache_write_1h_tokens: null })
  ]);
  const groups = buildBreakdown(ledger.read, { by: 'project' }).groups;
  assert.deepEqual(groups.find((g) => g.key === 'split').cost_by_kind,
    kinds('0.040000', '0.000000', '0.000000', '0.006800'));
  assert.deepEqual(groups.find((g) => g.key === 'unsplit').cost_by_kind,
    kinds('0.040000', '0.000000', '0.000000', '0.005000'));
});

test('金额分项：先按每条记录取整，再汇总，不能从合并 token 重算', (t) => {
  const ledger = seed(t, ['one', 'two'].map((key) => record({ record_key: key,
    input_tokens: 1, cache_read_tokens: 3, cache_write_tokens: 0, cache_write_1h_tokens: 0 })));
  const group = buildBreakdown(ledger.read, { by: 'model' }).groups[0];
  assert.equal(group.cost_usd, '0.000008');
  assert.deepEqual(group.cost_by_kind, kinds('0.000008', '0.000000', '0.000000', '0.000000'));
});

test('金额分项：有价格且总额为零时返回四个零，全无价格时返回 null', (t) => {
  const ledger = seed(t, [
    record({ record_key: 'zero', model: 'claude-opus-5-5', input_tokens: 0,
      cache_write_tokens: 0, cache_write_1h_tokens: 0 }),
    record({ record_key: 'unknown', model: 'unknown-model' })
  ]);
  const groups = buildBreakdown(ledger.read, { by: 'model' }).groups;
  assert.deepEqual(groups.find((g) => g.key === 'claude-opus-5-5').cost_by_kind, zero);
  assert.equal(groups.find((g) => g.key === 'unknown-model').cost_by_kind, null);
  assert.equal(groups.find((g) => g.key === 'unknown-model').cost_usd, null);
});

test('金额分项：部分记录未定价时，只汇总已定价的部分并保留未定价计数', (t) => {
  const ledger = seed(t, [record(), record({ record_key: 'unknown', model: null })]);
  const group = buildBreakdown(ledger.read, { by: 'source' }).groups[0];
  assert.equal(group.record_count, 2);
  assert.equal(group.unpriced_records, 1);
  assert.equal(group.cost_usd, '0.048000');
  assert.deepEqual(group.cost_by_kind, kinds('0.040000', '0.000000', '0.000000', '0.008000'));
});

for (const version of ['old-version', null]) {
  test(`金额分项：价格版本为 ${version} 时保留存储总额，分项返回 null`, (t) => {
    const ledger = seed(t, [record()], (row) => ({ ...costOf(row), price_version: version }));
    const before = ledger.read.totals();
    const group = buildBreakdown(ledger.read, { by: 'source' }).groups[0];
    assert.equal(group.cost_usd, '0.048000');
    assert.equal(group.cost_by_kind, null);
    assert.deepEqual(ledger.read.totals(), before);
  });
}

test('金额分项：逐行核对存储金额，两个相反差额不能在聚合后互相抵消', (t) => {
  const ledger = seed(t, [record({ record_key: 'plus' }), record({ record_key: 'minus' })],
    (row) => ({ ...costOf(row), cost_micros: costOf(row).cost_micros + (row.record_key === 'plus' ? 1 : -1) }));
  const group = buildBreakdown(ledger.read, { by: 'source' }).groups[0];
  assert.equal(group.cost_usd, '0.096000');
  assert.equal(group.cost_by_kind, null);
});

test('金额分项：同组有一个旧版本记录就不伪造整组拆分', (t) => {
  const ledger = seed(t, [record({ record_key: 'current' }), record({ record_key: 'old' })],
    (row) => ({ ...costOf(row), ...(row.record_key === 'old' ? { price_version: 'old' } : {}) }));
  const group = buildBreakdown(ledger.read, { by: 'source' }).groups[0];
  assert.equal(group.cost_usd, '0.096000');
  assert.equal(group.cost_by_kind, null);
});

test('金额分项：某组价格版本过期不影响其他可核对分组', (t) => {
  const ledger = seed(t, [record({ record_key: 'current', project_key: 'current' }),
    record({ record_key: 'old', project_key: 'old' })],
  (row) => ({ ...costOf(row), ...(row.record_key === 'old' ? { price_version: 'old' } : {}) }));
  const groups = buildBreakdown(ledger.read, { by: 'project' }).groups;
  assert.equal(groups.find((g) => g.key === 'old').cost_by_kind, null);
  assert.deepEqual(groups.find((g) => g.key === 'current').cost_by_kind,
    kinds('0.040000', '0.000000', '0.000000', '0.008000'));
});

test('金额分项：聚合后记录变化导致分项总额不一致时返回 null', (t) => {
  const ledger = seed(t, [record()]);
  const queries = {
    totals: (filter) => ledger.read.totals(filter),
    breakdown: (by, filter) => {
      const groups = ledger.read.breakdown(by, filter);
      ledger.write.ingestBatch([record({ input_tokens: 20_000 })], { priceOf: costOf });
      return groups;
    },
    costRows: (filter) => ledger.read.costRows(filter)
  };
  const group = buildBreakdown(queries, { by: 'source' }).groups[0];
  assert.equal(group.cost_usd, '0.048000');
  assert.equal(group.cost_by_kind, null);
  assert.equal(ledger.read.totals().cost_micros, 88_000);
});

test('金额分项：未知模型即使有已存金额，也不能按当前价表编造分项', (t) => {
  const ledger = seed(t, [record({ model: 'unknown-model' })], (row) => ({ ...costOf(row), cost_micros: 10 }));
  const group = buildBreakdown(ledger.read, { by: 'model' }).groups[0];
  assert.equal(group.cost_usd, '0.000010');
  assert.equal(group.cost_by_kind, null);
});

test('金额分项：没有单独缓存写单价的模型保持原来的零费用口径', (t) => {
  const ledger = seed(t, [record({ model: 'gpt-5.3-codex' })]);
  const group = buildBreakdown(ledger.read, { by: 'model' }).groups[0];
  assert.equal(group.cost_usd, '0.017500');
  assert.deepEqual(group.cost_by_kind, kinds('0.017500', '0.000000', '0.000000', '0.000000'));
});

test('金额分项：项目 NULL 与空字符串分别分组，不共用一份金额', (t) => {
  const ledger = seed(t, [record({ record_key: 'none', project_key: null }),
    record({ record_key: 'empty', project_key: '', input_tokens: 0 })]);
  const groups = buildBreakdown(ledger.read, { by: 'project' }).groups;
  assert.deepEqual(groups.find((g) => g.key === null).cost_by_kind,
    kinds('0.040000', '0.000000', '0.000000', '0.008000'));
  assert.deepEqual(groups.find((g) => g.key === '').cost_by_kind,
    kinds('0.000000', '0.000000', '0.000000', '0.008000'));
});

test('金额分项：路由筛选按相同时区切窗，旧版本的窗外记录不污染分项', async (t) => {
  const ledger = seed(t, [record({ observed_at: '2026-10-19T23:30:00Z' }),
    record({ record_key: 'outside', observed_at: '2026-10-21T00:00:00Z' }),
    record({ record_key: 'other-source', source: 'other' }),
    record({ record_key: 'other-project', project_key: '/work/other' }),
    record({ record_key: 'other-model', model: 'deepseek-flash' })],
  (row) => ({ ...costOf(row), ...(row.record_key === 'outside' ? { price_version: 'old' } : {}) }));
  const router = createRouter({ queries: ledger.read,
    json: (_req, res, body) => { res.body = body; } });
  const res = {};
  await router({ method: 'GET', url: '/api/v1/usage/breakdown?by=source&source=claude&model=claude-opus-5-5&project=%2Fwork%2Fapp&from=2026-10-20&to=2026-10-20&tz=Asia%2FShanghai' },
    res, '/api/v1/usage/breakdown');
  assert.equal(res.body.groups.length, 1);
  assert.equal(res.body.groups[0].record_count, 1);
  assert.deepEqual(res.body.groups[0].cost_by_kind, kinds('0.040000', '0.000000', '0.000000', '0.008000'));
});

test('金额分项：读取不改写历史行，inactive 记录不参与查询', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-cost-parts-'));
  const file = join(dir, 'ledger.db');
  const ledger = new Ledger(file);
  ledger.write.ingestBatch([record(), record({ record_key: 'inactive', input_tokens: 50_000 })], { priceOf: costOf });
  const raw = new DatabaseSync(file);
  t.after(() => {
    raw.close();
    ledger.close();
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  });
  raw.exec("UPDATE usage_records SET active = 0 WHERE record_key = 'inactive'");
  const before = raw.prepare('SELECT * FROM usage_records ORDER BY id').all();
  const group = buildBreakdown(ledger.read, { by: 'source' }).groups[0];
  assert.equal(group.record_count, 1);
  assert.deepEqual(group.cost_by_kind, kinds('0.040000', '0.000000', '0.000000', '0.008000'));
  assert.deepEqual(raw.prepare('SELECT * FROM usage_records ORDER BY id').all(), before);
  assert.equal(raw.prepare('PRAGMA user_version').get().user_version, 5);
});

test('HTTP：鉴权后的 breakdown 返回正确分项，旧价组保持已存总额', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-cost-http-'));
  const previous = process.env.TOKEN_LENS_DATA_DIR;
  let runtime;
  try {
    process.env.TOKEN_LENS_DATA_DIR = dir;
    const { startServer } = await import('../../src/core/server.js');
    runtime = await startServer(19230);
  } finally {
    if (previous === undefined) delete process.env.TOKEN_LENS_DATA_DIR;
    else process.env.TOKEN_LENS_DATA_DIR = previous;
  }
  t.after(async () => {
    await new Promise((resolve, reject) => runtime.server.close((error) => error ? reject(error) : resolve()));
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  });
  runtime.ledger.write.ingestBatch([record(), record({ record_key: 'old', project_key: '/work/old' })], {
    priceOf: (row) => ({ ...costOf(row), ...(row.record_key === 'old' ? { price_version: 'old' } : {}) })
  });
  const response = await fetch(`http://127.0.0.1:${runtime.port}/api/v1/usage/breakdown?by=project`, {
    headers: { Authorization: `Bearer ${runtime.token}` }
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.totals.cost_usd, '0.096000');
  assert.deepEqual(body.groups.find((g) => g.key === '/work/app').cost_by_kind,
    kinds('0.040000', '0.000000', '0.000000', '0.008000'));
  assert.equal(body.groups.find((g) => g.key === '/work/old').cost_usd, '0.048000');
  assert.equal(body.groups.find((g) => g.key === '/work/old').cost_by_kind, null);
});
