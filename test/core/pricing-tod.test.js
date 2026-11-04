import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf, priceRecord, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { CATALOG, checkEntry, versionOf } from '../../src/core/pricing/catalog.js';
import { buildBreakdown } from '../../src/core/api/v1/usage.js';

// deepseek-flash：高峰 输入 0.3 / 输出 1.2 / 缓存读 0.006；低谷减半
const row = (overrides = {}) => ({
  source: 'dsh', record_key: 'r', session_id: 's', project_key: null,
  model: 'deepseek-flash', kind: 'event', observed_at: '2026-10-26T02:00:00Z', ended_at: null,
  input_tokens: 1_000_000, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
  ...overrides
});
const input = (r) => priceRecord(row(r)).parts.input;
const source = (r) => priceRecord(row(r)).price_source;

test('峰谷：工作日北京时间高峰内按高峰价', () => {
  assert.equal(input({ observed_at: '2026-10-26T02:00:00Z' }), 300_000); // 周一 10:00
  assert.equal(source({ observed_at: '2026-10-26T02:00:00Z' }), 'verified:deepseek-flash;tod:peak');
  assert.equal(input({ observed_at: '2026-10-26T07:30:00Z' }), 300_000); // 周一 15:30
});

test('峰谷：工作日午休与晚间按低谷价', () => {
  assert.equal(input({ observed_at: '2026-10-26T05:00:00Z' }), 150_000); // 13:00
  assert.equal(source({ observed_at: '2026-10-26T05:00:00Z' }), 'verified:deepseek-flash;tod:offpeak');
  assert.equal(input({ observed_at: '2026-10-26T12:00:00Z' }), 150_000); // 20:00
});

test('峰谷：时段左闭右开，09:00 是高峰，12:00 与 18:00 是低谷', () => {
  assert.equal(input({ observed_at: '2026-10-26T01:00:00Z' }), 300_000);
  assert.equal(input({ observed_at: '2026-10-26T00:59:59.999Z' }), 150_000);
  assert.equal(input({ observed_at: '2026-10-26T04:00:00Z' }), 150_000);
  assert.equal(input({ observed_at: '2026-10-26T10:00:00Z' }), 150_000);
});

test('峰谷：按北京时间判断星期，UTC 周日晚上已是北京周一上午', () => {
  assert.equal(input({ observed_at: '2026-10-25T23:00:00Z' }), 150_000); // 北京周一 07:00
  assert.equal(input({ observed_at: '2026-10-26T10:30:00+08:00' }), 300_000); // 带偏移的写法
});

test('峰谷：周末、法定节假日全天按低谷，周末补班日也按低谷', () => {
  assert.equal(input({ observed_at: '2026-10-24T02:00:00Z' }), 150_000); // 周六
  assert.equal(input({ observed_at: '2026-10-01T02:00:00Z' }), 150_000); // 国庆，周四
  assert.equal(input({ observed_at: '2026-10-07T02:00:00Z' }), 150_000); // 国庆调休，周三
  assert.equal(input({ observed_at: '2026-10-10T02:00:00Z' }), 150_000); // 补班，周六
  assert.equal(input({ observed_at: '2026-10-09T02:00:00Z' }), 300_000); // 假后周五
});

test('峰谷：累计快照按区间内高峰与低谷的秒数加权', () => {
  // 北京周一 08:00–12:00：高峰 3 小时、低谷 1 小时
  const p = priceRecord(row({ kind: 'cumulative', observed_at: '2026-10-26T00:00:00Z', ended_at: '2026-10-26T04:00:00Z' }));
  assert.equal(p.parts.input, 262_500);
  assert.equal(p.price_source, 'verified:deepseek-flash;tod:blend');
});

test('峰谷：累计快照跨节假日，节假日不算高峰', () => {
  // 9/30 周三高峰 7 小时；10/1、10/2 国庆全天低谷；共 72 小时
  const p = priceRecord(row({ kind: 'cumulative', observed_at: '2026-09-29T16:00:00Z', ended_at: '2026-10-02T16:00:00Z' }));
  assert.equal(p.parts.input, 164_583);
});

test('峰谷：累计快照结束时间未知或与开始相同，用一周固定占比', () => {
  // 每周高峰 5 × 7 = 35 小时，占 168 小时
  for (const ended_at of [null, '2026-10-26T02:00:00Z']) {
    const p = priceRecord(row({ kind: 'cumulative', observed_at: '2026-10-26T02:00:00Z', ended_at }));
    assert.equal(p.parts.input, 181_250);
    assert.equal(p.price_source, 'verified:deepseek-flash;tod:weekly');
  }
});

test('峰谷：缓存读与输出同样按时段，单价为空的缓存写仍为 0', () => {
  const p = priceRecord(row({ observed_at: '2026-10-26T05:00:00Z', input_tokens: 0, output_tokens: 1_000_000,
    cache_read_tokens: 1_000_000, cache_write_tokens: 1_000_000 }));
  assert.deepEqual(p.parts, { input: 0, output: 600_000, cache_read: 3000, cache_write: 0 });
});

test('峰谷：入账、重算与分项核对一致，累计快照用到结束时间', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  const snap = row({ record_key: 'snap', kind: 'cumulative', observed_at: '2026-10-26T00:00:00Z', ended_at: '2026-10-26T04:00:00Z' });
  ledger.write.ingestBatch([snap], { priceOf: costOf });
  const group = buildBreakdown(ledger.read, { by: 'model' }).groups[0];
  assert.equal(group.cost_usd, '0.262500');
  assert.notEqual(group.cost_by_kind, null);
  ledger.write.ingestBatch([snap], { priceOf: () => ({ cost_micros: 1, price_version: 'old', price_source: 'x' }) });
  ledger.write.reprice(costOf, PRICE_VERSION);
  assert.equal(ledger.read.costRows({}).next().value.cost_micros, 262_500);
});

test('价表校验：同一条目不能同时写分档和峰谷，时段写错要报错', () => {
  const deepseek = CATALOG.find((e) => e.id === 'deepseek-flash');
  assert.doesNotThrow(() => checkEntry(deepseek));
  assert.throws(() => checkEntry({ ...deepseek, tiers: [{ above: 1, perMTok: deepseek.perMTok }] }), /tiers.*timeOfDay|timeOfDay.*tiers/);
  const bad = (timeOfDay) => () => checkEntry({ ...deepseek, timeOfDay: { ...deepseek.timeOfDay, ...timeOfDay } });
  assert.throws(bad({ peak: [{ days: [1], from: 720, to: 540 }] }));
  assert.throws(bad({ peak: [{ days: [7], from: 0, to: 60 }] }));
  assert.throws(bad({ holidays: ['2026-13-01'] }));
  assert.throws(bad({ offPeak: { input: 0.15 } }));
});

test('价格版本：节假日表变化会换版本', () => {
  const changed = CATALOG.map((e) => e.timeOfDay
    ? { ...e, timeOfDay: { ...e.timeOfDay, holidays: [...e.timeOfDay.holidays, '2027-01-01'] } } : e);
  assert.notEqual(versionOf(changed), PRICE_VERSION);
});
