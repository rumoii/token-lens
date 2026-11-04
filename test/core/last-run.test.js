import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Ledger } from '../../src/core/db/ledger.js';
import { buildSources } from '../../src/core/api/v1/sources.js';

const emptyStats = { attempted: 0, inserted: 0, updated: 0, unchanged: 0, rejected: 0, anomalies: [] };

test('从未采集过时 lastRun 与 last_run 都是 null', () => {
  const ledger = new Ledger(':memory:');
  assert.equal(ledger.read.lastRun(), null);
  assert.equal(buildSources(ledger.read).last_run, null);
  ledger.close();
});

test('采集运行后 lastRun 带统计与异常', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.recordRun('completed_with_anomalies', {
    attempted: 10, inserted: 7, updated: 1, unchanged: 1, rejected: 1,
    anomalies: ['read_failed: claude /x — boom']
  });

  const run = ledger.read.lastRun();
  assert.equal(run.status, 'completed_with_anomalies');
  assert.equal(run.attempted, 10);
  assert.equal(run.inserted, 7);
  assert.equal(run.rejected, 1);
  assert.deepEqual(run.anomalies, ['read_failed: claude /x — boom']);
  ledger.close();
});

test('最近一次运行胜出', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.recordRun('ok', { ...emptyStats, attempted: 1, inserted: 1, anomalies: ['旧异常'] });
  ledger.write.recordRun('ok', { ...emptyStats, attempted: 2, inserted: 2 });

  const run = ledger.read.lastRun();
  assert.equal(run.attempted, 2);
  assert.equal(run.anomalies.length, 0, '旧运行的异常不应残留');
  ledger.close();
});

test('buildSources 输出 ISO 时间并截断异常列表', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.recordRun('completed_with_anomalies', {
    ...emptyStats,
    attempted: 3, inserted: 1, updated: 1, rejected: 1,
    anomalies: ['a', 'b', 'c', 'd', 'e', 'f', 'g']
  });

  const out = buildSources(ledger.read);
  assert.ok(out.last_run, '应当带出最近一次运行');
  assert.equal(out.last_run.status, 'completed_with_anomalies');
  assert.equal(out.last_run.attempted, 3);
  assert.equal(out.last_run.rejected, 1);
  assert.equal(out.last_run.anomaly_count, 7);
  assert.equal(out.last_run.anomalies.length, 5, '最多带出 5 条');
  assert.match(String(out.last_run.finished_at), /^\d{4}-\d{2}-\d{2}T/, '时间转成 ISO');
  ledger.close();
});
