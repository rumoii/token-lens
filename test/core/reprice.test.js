import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';

const priceA = () => ({ cost_micros: 1000, price_version: 'vA', price_source: 'verified:x' });
const priceB = () => ({ cost_micros: 250, price_version: 'vB', price_source: 'verified:x' });

function seed(ledger) {
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'k1', model: 'claude-opus-5-5',
      observed_at: '2026-10-10T00:00:00.000Z', kind: 'event',
      input_tokens: 10, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0 },
    { source: 'codex', record_key: 'k2', model: 'gpt-6.1-sol',
      observed_at: '2026-10-11T00:00:00.000Z', kind: 'event',
      input_tokens: 20, output_tokens: 2, cache_read_tokens: 0, cache_write_tokens: null }
  ], { priceOf: priceA });
}

test('价格版本变化后重算金额，用量不变', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);
  assert.equal(ledger.read.totals().cost_micros, 2000);

  const changed = ledger.write.reprice(priceB, 'vB');
  assert.equal(changed, 2, '两条记录都应重算');

  const row = ledger.read.totals();
  assert.equal(row.cost_micros, 500, '金额按新版本');
  assert.equal(row.gross_tokens, 33, '用量事实不变');
  ledger.close();
});

test('同一价格版本重复重算不改动任何行', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);
  assert.equal(ledger.write.reprice(priceA, 'vA'), 0);
  ledger.close();
});

test('重算会写入价格快照版本', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);
  ledger.write.reprice(priceB, 'vB');
  const versions = ledger.read.priceVersions();
  assert.deepEqual(versions, ['vB']);
  ledger.close();
});

test('reprice 在写事务内读取候选行，空结果也结束事务', (t) => {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  let reads = 0;
  // 只观察真实 SQLite 查询执行时的事务状态，不替换查询结果或写入。
  const writer = new LedgerWriter({
    exec: (sql) => db.exec(sql),
    prepare(sql) {
      const statement = db.prepare(sql);
      if (!/SELECT[\s\S]*FROM usage_records[\s\S]*price_version/.test(sql)) return statement;
      return {
        all(...args) {
          reads += 1;
          assert.equal(db.isTransaction, true, '候选行 SELECT 必须在 BEGIN IMMEDIATE 之后执行');
          return statement.all(...args);
        }
      };
    }
  });
  seed({ write: writer });
  assert.equal(writer.reprice(priceB, 'vB'), 2);
  assert.equal(db.isTransaction, false);
  const snapshot = db.prepare('SELECT * FROM pricing_snapshot').all();
  assert.equal(writer.reprice(priceB, 'vB'), 0);
  assert.equal(db.isTransaction, false, '没有候选行也不能泄漏事务');
  assert.equal(reads, 2, '有候选行及空结果均检查事务边界');
  assert.deepEqual(db.prepare('SELECT * FROM pricing_snapshot').all(), snapshot);
  assert.equal(writer.ingestBatch([{
    source: 'test', record_key: 'after-empty-reprice', observed_at: '2026-10-12T00:00:00.000Z', input_tokens: 1
  }]).inserted, 1, '空结果返回后仍可开始新写事务');
});
