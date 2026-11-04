import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';

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
