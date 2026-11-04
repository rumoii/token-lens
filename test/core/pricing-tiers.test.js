import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf, priceRecord, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { CATALOG, versionOf } from '../../src/core/pricing/catalog.js';
import { buildBreakdown } from '../../src/core/api/v1/usage.js';

const row = (overrides = {}) => ({
  source: 'codex', record_key: 'r', session_id: 's', project_key: null,
  model: 'gpt-6.1-sol', kind: 'event', observed_at: '2026-10-20T00:00:00Z',
  input_tokens: 0, output_tokens: 1000, cache_read_tokens: 0, cache_write_tokens: 0,
  ...overrides
});
const parts = (input, output, cache_read, cache_write) => ({ input, output, cache_read, cache_write });

test('长上下文：提示超过阈值时整条请求按高档计价，标出所用档位', () => {
  const p = priceRecord(row({ input_tokens: 1, cache_read_tokens: 272_000 }));
  // gpt-6.1-sol 长档：输入 4、缓存读 0.20、缓存写 5、输出 15（USD / 1M）
  assert.deepEqual(p.parts, parts(4, 15_000, 54_400, 0));
  assert.equal(p.cost_micros, 69_404);
  assert.equal(p.price_source, 'verified:gpt-6.1-sol;tier:272000');
});

test('长上下文：恰好等于阈值仍是基础档（官网写的是 ≤272K 为短上下文）', () => {
  const p = priceRecord(row({ input_tokens: 0, cache_read_tokens: 272_000 }));
  assert.deepEqual(p.parts, parts(0, 10_000, 27_200, 0));
  assert.equal(p.price_source, 'verified:gpt-6.1-sol');
});

test('长上下文：提示长度含缓存写', () => {
  const p = priceRecord(row({ input_tokens: 100_000, cache_read_tokens: 100_000, cache_write_tokens: 72_001 }));
  assert.equal(p.price_source, 'verified:gpt-6.1-sol;tier:272000');
  assert.equal(p.parts.cache_write, 360_005);
});

test('长上下文：某项未知但已知部分已超过阈值，照样用高档', () => {
  const p = priceRecord(row({ input_tokens: 300_000, cache_write_tokens: null }));
  assert.equal(p.price_source, 'verified:gpt-6.1-sol;tier:272000');
  assert.equal(p.parts.input, 1_200_000);
});

test('长上下文：某项未知且已知部分未超过阈值，用基础档并标 tier:unknown', () => {
  const p = priceRecord(row({ input_tokens: 1000, cache_write_tokens: null }));
  assert.equal(p.price_source, 'verified:gpt-6.1-sol;tier:unknown');
  assert.deepEqual(p.parts, parts(2000, 10_000, 0, 0));
});

test('长上下文：累计快照用基础档并标 tier:cumulative', () => {
  const p = priceRecord(row({ kind: 'cumulative', input_tokens: 5_000_000 }));
  assert.equal(p.price_source, 'verified:gpt-6.1-sol;tier:cumulative');
  assert.equal(p.parts.input, 10_000_000);
});

test('长上下文：没有分档的模型不加任何标记', () => {
  const p = priceRecord(row({ model: 'claude-opus-5-5', kind: 'cumulative', input_tokens: 900_000 }));
  assert.equal(p.price_source, 'verified:claude-opus-5-5');
});

test('Haiku 5.5：提示超过 100,000 时按高档，1 小时缓存写有自己的单价', () => {
  const base = priceRecord(row({ model: 'claude-haiku-5-5', input_tokens: 1000, cache_write_tokens: 1000,
    cache_write_5m_tokens: 0, cache_write_1h_tokens: 1000 }));
  assert.equal(base.price_source, 'verified:claude-haiku-5-5');
  assert.equal(base.parts.cache_write, 200, '基础档 1 小时缓存写 0.20 / MTok');
  const high = priceRecord(row({ model: 'claude-haiku-5-5', input_tokens: 1000, cache_read_tokens: 99_001,
    cache_write_tokens: 1000, cache_write_5m_tokens: 0, cache_write_1h_tokens: 1000 }));
  assert.equal(high.price_source, 'verified:claude-haiku-5-5;tier:100000');
  assert.deepEqual(high.parts, parts(500, 2500, 4950, 1000));
});

test('长上下文：入账、重算与分项核对用同一组字段，结果一致', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  const long = row({ record_key: 'long', project_key: 'long', input_tokens: 1, cache_read_tokens: 272_000 });
  // 入账时适配器没写 kind，账本按 event 存，计价也必须按 event
  const { kind, ...withoutKind } = long;
  ledger.write.ingestBatch([withoutKind], { priceOf: costOf });
  const stored = () => ledger.read.costRows({}).next().value;
  assert.equal(stored().cost_micros, 69_404);
  assert.equal(stored().kind, 'event');

  const group = buildBreakdown(ledger.read, { by: 'project' }).groups[0];
  assert.equal(group.cost_usd, '0.069404');
  assert.notEqual(group.cost_by_kind, null, '逐行核对必须拿到 kind，否则会把正确金额判成不匹配');

  ledger.write.ingestBatch([long], { priceOf: () => ({ cost_micros: 1, price_version: 'old', price_source: 'x' }) });
  ledger.write.reprice(costOf, PRICE_VERSION);
  assert.equal(stored().cost_micros, 69_404);
});

test('价格版本：分档内容变化会换版本', () => {
  const changed = CATALOG.map((e) => e.id === 'gpt-6.1-sol'
    ? { ...e, tiers: [{ ...e.tiers[0], above: 500_000 }] } : e);
  assert.equal(versionOf(CATALOG), PRICE_VERSION);
  assert.notEqual(versionOf(changed), PRICE_VERSION);
});

test('长上下文：累计快照的分项核对必须按累计计价，不能当成单次请求', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch([row({ record_key: 'snap', kind: 'cumulative', input_tokens: 5_000_000 })], { priceOf: costOf });
  const group = buildBreakdown(ledger.read, { by: 'model' }).groups[0];
  assert.equal(group.cost_usd, '10.010000');
  assert.deepEqual(group.cost_by_kind, { input: '10.000000', output: '0.010000', cache_read: '0.000000', cache_write: '0.000000' });
});
