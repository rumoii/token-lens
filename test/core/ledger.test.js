import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';

const base = {
  source: 'claude',
  record_key: 'claude|s1|msg_01',
  session_id: 's1',
  model: 'claude-opus-4-1',
  observed_at: '2026-10-10T01:00:00.000Z',
  kind: 'event',
  input_tokens: 100,
  output_tokens: 50,
  cache_read_tokens: 0,
  cache_write_tokens: 0
};

test('同一身份重复读到：不新增行，内容不变则计为 unchanged', () => {
  const ledger = new Ledger(':memory:');
  const first = ledger.write.ingestBatch([base]);
  const second = ledger.write.ingestBatch([base]);
  const totals = ledger.read.totals();

  assert.equal(first.inserted, 1);
  assert.equal(second.inserted, 0);
  assert.equal(second.unchanged, 1);
  assert.equal(totals.record_count, 1);
  assert.equal(totals.input_tokens, 100);
  ledger.close();
});

test('同一身份用量增长：更新原行、revision 递增，不新增行', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([base]);
  const grown = ledger.write.ingestBatch([{ ...base, input_tokens: 200, output_tokens: 80 }]);
  const totals = ledger.read.totals();

  assert.equal(grown.updated, 1);
  assert.equal(grown.inserted, 0);
  assert.equal(totals.record_count, 1);
  assert.equal(totals.input_tokens, 200);
  assert.equal(totals.output_tokens, 80);
  ledger.close();
});

test('累计源增长：覆盖不累加', () => {
  const ledger = new Ledger(':memory:');
  const cumulative = { ...base, source: 'hermes', record_key: 'hermes|h1', kind: 'cumulative' };
  ledger.write.ingestBatch([cumulative]);
  ledger.write.ingestBatch([{ ...cumulative, input_tokens: 3000, output_tokens: 600 }]);
  const totals = ledger.read.totals();

  assert.equal(totals.record_count, 1);
  assert.equal(totals.input_tokens, 3000);
  ledger.close();
});

test('累计源下降：不覆盖、记为异常', () => {
  const ledger = new Ledger(':memory:');
  const cumulative = { ...base, source: 'hermes', record_key: 'hermes|h1', kind: 'cumulative', input_tokens: 3000 };
  ledger.write.ingestBatch([cumulative]);
  const down = ledger.write.ingestBatch([{ ...cumulative, input_tokens: 1000 }]);
  const totals = ledger.read.totals();

  assert.equal(down.updated, 0);
  assert.equal(down.anomalies.length, 1);
  assert.match(down.anomalies[0], /cumulative_decrease/);
  assert.equal(totals.input_tokens, 3000, '旧值必须保留，不能被下降值覆盖');
  ledger.close();
});

test('缺 record_key 的记录被拒绝，不入库', () => {
  const ledger = new Ledger(':memory:');
  const stats = ledger.write.ingestBatch([{ ...base, record_key: '' }]);
  assert.equal(stats.rejected, 1);
  assert.equal(stats.inserted, 0);
  assert.equal(ledger.read.totals().record_count, 0);
  ledger.close();
});

test('未知 token 保持 null，不被折成 0', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([
    { ...base, record_key: 'k1', input_tokens: null, output_tokens: null, cache_read_tokens: null, cache_write_tokens: null },
    { ...base, record_key: 'k2', input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 }
  ]);
  const row = ledger.read.totals();

  assert.equal(row.input_unknown, 1, '一条未知');
  assert.equal(row.input_tokens, 0, '求和只算已知值');
  assert.equal(row.record_count, 2);
  ledger.close();
});

test('金额未知不进总额，单独计数', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([base], {
    priceOf: () => ({ cost_micros: null, price_version: 'v1', price_source: null })
  });
  ledger.write.ingestBatch([{ ...base, record_key: 'k2' }], {
    priceOf: () => ({ cost_micros: 1234, price_version: 'v1', price_source: 'x' })
  });
  const row = ledger.read.totals();

  assert.equal(row.cost_micros, 1234);
  assert.equal(row.unpriced_records, 1);
  ledger.close();
});

test('gross 恒等于四类 token 之和', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([
    { ...base, record_key: 'a', input_tokens: 10, output_tokens: 20, cache_read_tokens: 30, cache_write_tokens: 40 }
  ]);
  const row = ledger.read.totals();
  assert.equal(row.gross_tokens, 100);
  assert.equal(
    row.gross_tokens,
    row.input_tokens + row.output_tokens + row.cache_read_tokens + row.cache_write_tokens
  );
  ledger.close();
});

test('空数据集是 0，不是未知', () => {
  const ledger = new Ledger(':memory:');
  const row = ledger.read.totals();
  assert.equal(row.record_count, 0);
  assert.equal(row.gross_tokens, 0);
  assert.equal(row.input_tokens, 0, '没有记录时 0 才是真值');
  assert.equal(row.cost_micros, 0);
  ledger.close();
});
