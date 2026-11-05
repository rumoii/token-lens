import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter, payloadHash } from '../../src/core/db/write.js';

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

const oldEnd = '2026-10-10T02:00:00.000Z';
const newEnd = '2026-10-10T03:00:00.000Z';
const timePrice = (r) => ({
  cost_micros: r.input_tokens * (r.ended_at === oldEnd ? 2 : r.ended_at === newEnd ? 3 : 7),
  price_version: 'time-v1', price_source: 'test:ended_at'
});

function cumulativeFixture(t) {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  const writer = new LedgerWriter(db);
  const initial = { ...base, source: 'dsh', record_key: 'dsh|s1', kind: 'cumulative', ended_at: oldEnd };
  const grown = { ...initial, input_tokens: 200, ended_at: null };
  const options = { priceOf: timePrice };
  writer.ingestBatch([initial], options);
  return { db, writer, grown, options, read: () => db.prepare('SELECT * FROM usage_records').get() };
}

test('累计快照：null 结束时间沿用旧值，金额与 hash 对应同一条有效记录', (t) => {
  const { writer, grown, options, read } = cumulativeFixture(t);
  assert.equal(writer.ingestBatch([grown], options).updated, 1);
  const stored = read();
  const effective = { ...grown, ended_at: oldEnd };
  assert.deepEqual(
    { ended_at: stored.ended_at, cost_micros: stored.cost_micros, content_hash: stored.content_hash },
    { ended_at: oldEnd, cost_micros: timePrice(effective).cost_micros, content_hash: payloadHash(effective) }
  );
  assert.equal(stored.revision, 2);
  assert.equal(grown.ended_at, null, '不修改适配器的输入记录');
});

test('累计快照：相同 null 输入再次采集为 unchanged，revision 不变', (t) => {
  const { writer, grown, options, read } = cumulativeFixture(t);
  writer.ingestBatch([grown], options);
  const before = read();
  const stats = writer.ingestBatch([grown], options);
  assert.equal(stats.unchanged, 1);
  assert.equal(stats.updated, 0);
  assert.deepEqual(read(), before);
});

test('累计快照：后来给出的新结束时间覆盖旧值，并重新计算金额和 hash', (t) => {
  const { writer, grown, options, read } = cumulativeFixture(t);
  writer.ingestBatch([grown], options);
  const later = { ...grown, ended_at: newEnd };
  assert.equal(writer.ingestBatch([later], options).updated, 1);
  const stored = read();
  assert.equal(stored.ended_at, newEnd);
  assert.equal(stored.cost_micros, timePrice(later).cost_micros);
  assert.equal(stored.content_hash, payloadHash(later));
  assert.equal(stored.revision, 3);
});

test('累计快照：旧版按 null 时间存下的 hash 和金额在重读时修正一次', (t) => {
  const { db, writer, grown, options, read } = cumulativeFixture(t);
  db.prepare('UPDATE usage_records SET input_tokens = ?, content_hash = ?, cost_micros = ?, revision = 2')
    .run(grown.input_tokens, payloadHash(grown), timePrice(grown).cost_micros);
  assert.equal(writer.ingestBatch([grown], options).updated, 1);
  const effective = { ...grown, ended_at: oldEnd };
  assert.equal(read().cost_micros, timePrice(effective).cost_micros);
  assert.equal(read().content_hash, payloadHash(effective));
  assert.equal(read().revision, 3);
  assert.equal(writer.ingestBatch([grown], options).unchanged, 1);
  assert.equal(read().revision, 3);
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
