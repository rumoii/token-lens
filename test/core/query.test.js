import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf, formatMicros, allocateDisplay, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { classifyPrice } from '../../src/core/pricing/catalog.js';

const priceOf = (r) => costOf(r);

function seed(ledger) {
  const rows = [
    // 跨日、跨月、多模型、多来源、含缓存读写
    { source: 'claude', record_key: 'c1', session_id: 's1', model: 'claude-opus-4-1', observed_at: '2026-09-30T10:00:00.000Z', kind: 'event',
      input_tokens: 1000, output_tokens: 500, cache_read_tokens: 200, cache_write_tokens: 100 },
    { source: 'claude', record_key: 'c2', session_id: 's1', model: 'claude-sonnet-4', observed_at: '2026-10-01T10:00:00.000Z', kind: 'event',
      input_tokens: 2000, output_tokens: 800, cache_read_tokens: 0, cache_write_tokens: 0 },
    { source: 'codex', record_key: 'x1', session_id: 's2', model: 'gpt-6.1-sol', observed_at: '2026-10-01T12:00:00.000Z', kind: 'event',
      input_tokens: 3000, output_tokens: 900, cache_read_tokens: 1500, cache_write_tokens: null },
    // 累计型：不参与时间序列
    { source: 'dsh', record_key: 'd1', session_id: 's3', model: 'deepseek-flash', observed_at: '2026-10-02T09:00:00.000Z', kind: 'cumulative',
      input_tokens: 400, output_tokens: 100, cache_read_tokens: 0, cache_write_tokens: 0 },
    // 未定价模型
    { source: 'mimo', record_key: 'm1', session_id: 's4', model: 'unknown-model-x', observed_at: '2026-10-02T11:00:00.000Z', kind: 'event',
      input_tokens: 50, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0 }
  ];
  ledger.write.ingestBatch(rows, { priceOf });
  return rows;
}

test('分组之和 == 总额（token 与金额）', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const totals = ledger.read.totals();
  for (const by of ['model', 'source', 'project']) {
    const groups = ledger.read.breakdown(by);
    const tokenSum = groups.reduce((s, g) => s + g.gross_tokens, 0);
    const costSum = groups.reduce((s, g) => s + (g.cost_micros || 0), 0);
    assert.equal(tokenSum, totals.gross_tokens, `${by} 的 token 分组和不等于总额`);
    assert.equal(costSum, totals.cost_micros || 0, `${by} 的金额分组和不等于总额`);
  }
  ledger.close();
});

test('时间序列 + 未分配 == 总额', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const totals = ledger.read.totals();
  const { points, unallocated } = ledger.read.timeseries('day');

  const pointTokens = points.reduce((s, p) => s + p.gross_tokens, 0);
  const unallocTokens = unallocated ? unallocated.gross_tokens : 0;
  assert.equal(pointTokens + unallocTokens, totals.gross_tokens);

  const pointCost = points.reduce((s, p) => s + (p.cost_micros || 0), 0);
  const unallocCost = unallocated ? (unallocated.cost_micros || 0) : 0;
  assert.equal(pointCost + unallocCost, totals.cost_micros || 0);

  assert.ok(unallocated, '累计型记录必须出现在未分配桶');
  assert.equal(unallocated.reason, 'cumulative_without_time_distribution');
  ledger.close();
});

test('跨月分组正确，且日视图不含累计型', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const months = ledger.read.timeseries('month');
  assert.deepEqual(months.points.map((p) => p.bucket), ['2026-09', '2026-10']);

  const { points } = ledger.read.timeseries('day');
  assert.ok(points.every((p) => p.bucket !== '2026-10-02' || p.gross_tokens !== 500),
    '累计型记录不能混进某一天');
  ledger.close();
});

test('金额用整数 micros，展示为十进制字符串', () => {
  const { cost_micros } = costOf({
    model: 'claude-opus-5-5', input_tokens: 1_000_000, output_tokens: 0,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  assert.equal(cost_micros, 4_000_000, '1M input × $4/1M = $4 = 4e6 micros');
  assert.equal(formatMicros(cost_micros), '4.000000');
  assert.equal(formatMicros(null), null);
});

test('未定价模型：金额为 null，并单独计数', () => {
  const r = costOf({ model: 'unknown-model-x', input_tokens: 10, output_tokens: 1,
    cache_read_tokens: 0, cache_write_tokens: 0 });
  assert.equal(r.cost_micros, null);
  assert.equal(r.price_source, null);
});

test('展示层尾差分配：分项之和严格等于总额', () => {
  const values = [333333, 333333, 333334];
  const total = values.reduce((a, b) => a + b, 0);
  const shown = allocateDisplay(values, total, 2);
  const sum = shown.reduce((a, s) => a + Math.round(Number(s) * 100), 0);
  assert.equal(sum, Math.round(Number(formatMicros(total, 2)) * 100));
});

test('价格版本随目录变化，且被写入记录', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([{ source: 'claude', record_key: 'k', model: 'claude-opus-5-5',
    observed_at: '2026-10-01T00:00:00.000Z', kind: 'event',
    input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0 }],
    { priceOf });
  const row = ledger.read.totals();
  assert.equal(row.record_count, 1);
  // (1×4 + 1×20)/1e6 USD = 24 micros
  assert.equal(row.cost_micros, 24);
  assert.ok(PRICE_VERSION);
  ledger.close();
});

test('金额按核验后的官方价计算', () => {
  const opus = costOf({
    model: 'claude-opus-5-5', input_tokens: 1_000_000, output_tokens: 1_000_000,
    cache_read_tokens: 1_000_000, cache_write_tokens: 0
  });
  // 4 + 20 + 0.20
  assert.equal(formatMicros(opus.cost_micros), '24.200000');

  const sol = costOf({
    model: 'gpt-6.1-sol', input_tokens: 100_000, output_tokens: 1_000_000,
    cache_read_tokens: 100_000, cache_write_tokens: 0
  });
  // 短上下文：0.2×2 + 10 + 0.1×0.10
  assert.equal(formatMicros(sol.cost_micros), '10.210000');
  const solLong = costOf({
    model: 'gpt-6.1-sol', input_tokens: 1_000_000, output_tokens: 1_000_000,
    cache_read_tokens: 1_000_000, cache_write_tokens: 0
  });
  // 提示 200 万 > 272K，长上下文：4 + 15 + 0.20
  assert.equal(formatMicros(solLong.cost_micros), '19.200000');

  const astra = costOf({
    model: 'gpt-6-astra', input_tokens: 200_000, output_tokens: 1_000_000,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  // 短上下文：0.2×10 + 50
  assert.equal(formatMicros(astra.cost_micros), '52.000000');
  const astraLong = costOf({
    model: 'gpt-6-astra', input_tokens: 1_000_000, output_tokens: 1_000_000,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  // 长上下文：20 + 75
  assert.equal(formatMicros(astraLong.cost_micros), '95.000000');
});

test('没有条目的型号一律未定价', () => {
  for (const model of ['doubao-pro-32k', 'glm-4-plus', 'claude-opus-4-1', 'qwen3:8b']) {
    const r = costOf({
      model, input_tokens: 1_000_000, output_tokens: 1_000_000,
      cache_read_tokens: null, cache_write_tokens: null
    });
    assert.equal(r.cost_micros, null, `${model} 不应命中价格`);
    assert.equal(r.price_source, null);
  }
});

test('套餐制模型照样给出市场价值，并标出计费方式', () => {
  const r = costOf({
    model: 'mimo-v2.6-pro', input_tokens: 1_000_000, output_tokens: 1_000_000,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  // 0.435 + 0.87
  assert.equal(formatMicros(r.cost_micros), '1.305000');
  assert.equal(r.price_source, 'verified:mimo-v2.6-pro');

  const cls = classifyPrice('mimo-v2.6-pro');
  assert.equal(cls.billing, 'plan', '套餐制要用 billing 表达，而不是判成无价');
  assert.equal(cls.state, 'verified');

  assert.equal(classifyPrice('claude-opus-5-5').billing, 'metered');
});

test('聚合来源与官方核验在 price_source 上分开标记', () => {
  const verified = costOf({
    model: 'claude-opus-5-5', input_tokens: 1, output_tokens: 0,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  assert.match(verified.price_source, /^verified:/);

  const aggregate = costOf({
    model: 'gemini-3.8-flash-n', input_tokens: 1_000_000, output_tokens: 0,
    cache_read_tokens: 0, cache_write_tokens: 0
  });
  assert.match(aggregate.price_source, /^aggregate:/);
  assert.equal(formatMicros(aggregate.cost_micros), '0.750000');
});

test('缓存写确实按官方费率计入', () => {
  const r = costOf({
    model: 'claude-opus-5-5', input_tokens: 0, output_tokens: 0,
    cache_read_tokens: 0, cache_write_tokens: 1_000_000
  });
  assert.equal(formatMicros(r.cost_micros), '5.000000');
});

test('带日期范围与偏移时，分组之和仍等于总额（同一日期语义）', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch(
    [
      // UTC 9/30 18:00 = 本地(+8) 10/1：两种切窗对它的归属不同
      { source: 'claude', record_key: 'w1', session_id: 's1', model: 'claude-opus-4-1', observed_at: '2026-09-30T18:00:00.000Z', kind: 'event',
        input_tokens: 1000, output_tokens: 500, cache_read_tokens: 0, cache_write_tokens: 0, project_key: 'p1' },
      { source: 'codex', record_key: 'w2', session_id: 's2', model: 'gpt-6.1-sol', observed_at: '2026-10-01T10:00:00.000Z', kind: 'event',
        input_tokens: 2000, output_tokens: 900, cache_read_tokens: 0, cache_write_tokens: 0, project_key: 'p2' }
    ],
    { priceOf }
  );

  for (const offsetMinutes of [0, 480]) {
    const filter = { from: '2026-10-01', to: '2026-10-01', offsetMinutes };
    const totals = ledger.read.totals(filter);
    for (const by of ['model', 'source', 'project']) {
      const tokenSum = ledger.read.breakdown(by, filter).reduce((s, g) => s + g.gross_tokens, 0);
      assert.equal(tokenSum, totals.gross_tokens, `${by} offset=${offsetMinutes} 的分组和不等于总额`);
    }
  }

  // 本地日界真的生效：+8 的 10/1 含 UTC 9/30 18:00 那条，UTC 的不含
  assert.equal(ledger.read.totals({ from: '2026-10-01', to: '2026-10-01', offsetMinutes: 0 }).record_count, 1);
  assert.equal(ledger.read.totals({ from: '2026-10-01', to: '2026-10-01', offsetMinutes: 480 }).record_count, 2);

  // project 过滤生效
  const p1 = ledger.read.totals({ project: 'p1' });
  assert.equal(p1.record_count, 1);
  assert.equal(p1.gross_tokens, 1500);
  ledger.close();
});
