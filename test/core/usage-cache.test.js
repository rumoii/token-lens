import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Ledger } from '../../src/core/db/ledger.js';
import { createRouter } from '../../src/core/api/router.js';

function seed(ledger, key = 'initial', observedAt = '2026-10-23T00:00:00.000Z') {
  ledger.write.ingestBatch([{
    source: 'claude', record_key: key, session_id: 'session', project_key: '/work/demo',
    model: 'claude-opus-5-5', observed_at: observedAt, kind: 'event',
    input_tokens: 10, output_tokens: 5, cache_read_tokens: 2, cache_write_tokens: 0
  }]);
}

function harness(t, ledger, now = () => new Date('2026-10-23T12:00:00Z')) {
  const router = createRouter({
    queries: ledger.read,
    now,
    meta: { version: 'test', port: 3456, dataDir: '/test-data', ledgerPath: '/test-data/ledger.db', schemaVersion: 5 },
    json: (_req, res, body, status = 200) => Object.assign(res, { body, status, payload: JSON.stringify(body) }),
    runSync: async () => ({ inserted: 0 }),
    discover: () => ({})
  });
  return async (path, method = 'GET') => {
    const res = {};
    const url = `/api/v1${path}`;
    assert.equal(await router({ url, method }, res, new URL(url, 'http://localhost').pathname), true);
    return res;
  };
}

function countCalls(target, names) {
  const calls = [];
  for (const name of names) {
    const original = target[name].bind(target);
    target[name] = (...args) => {
      calls.push(name);
      return original(...args);
    };
  }
  return calls;
}

test('五个 usage GET 仅缓存 200，第二次不重新查询且响应逐字节相同', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-23T12:00:00Z') });
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  seed(ledger);
  const calls = countCalls(ledger.read, ['totals', 'activity', 'timeseries', 'timeseriesGrouped', 'breakdown', 'grouped', 'costRows']);
  const get = harness(t, ledger);
  const paths = [
    '/usage/summary?tz=UTC&from=2026-10-23&extra=one&extra=two',
    '/usage/timeseries?tz=UTC&granularity=day',
    '/usage/matrix?tz=UTC&granularity=day&by=source',
    '/usage/breakdown?tz=UTC&by=source_model',
    '/usage/unallocated?tz=UTC'
  ];
  const first = [];
  for (const path of paths) first.push(await get(path));
  const count = calls.length;
  assert.ok(count > 0);
  t.mock.timers.setTime(new Date('2026-10-23T12:01:00Z').getTime());
  for (const [index, path] of paths.entries()) {
    const reordered = index === 0 ? '/usage/summary?extra=one&from=2026-10-23&extra=two&tz=UTC' : path;
    const second = await get(reordered);
    assert.equal(second.status, 200);
    assert.equal(second.payload, first[index].payload);
  }
  assert.equal(calls.length, count);
});

test('另一条连接提交写入后 data_version 使旧缓存失效并反映新数据', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-usage-cache-'));
  const path = join(dir, 'ledger.db');
  const ledger = new Ledger(path);
  t.after(() => {
    ledger.close();
    rmSync(dir, { recursive: true, force: true });
  });
  seed(ledger);
  const calls = countCalls(ledger.read, ['totals']);
  const get = harness(t, ledger);
  assert.equal((await get('/usage/summary?tz=UTC')).body.totals.record_count, 1);
  assert.equal((await get('/usage/summary?tz=UTC')).body.totals.record_count, 1);
  assert.equal(calls.length, 3);

  const writer = new DatabaseSync(path);
  writer.prepare(`
    INSERT INTO usage_records (record_key, content_hash, source, session_id, model, observed_at, kind,
      input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
    VALUES ('other-connection', 'hash-other', 'claude', 'session-2', 'claude-opus-5-5',
      '2026-10-23T01:00:00.000Z', 'event', 20, 10, 0, 0)
  `).run();
  writer.close();

  assert.equal((await get('/usage/summary?tz=UTC')).body.totals.record_count, 2);
  assert.equal(calls.length, 6);
});

test('tz、任一完整查询参数和注入的本地日期都参与缓存键', async (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  seed(ledger);
  let now = new Date('2026-10-23T15:00:00Z');
  const calls = countCalls(ledger.read, ['totals']);
  const get = harness(t, ledger, () => now);
  const path = '/usage/summary?tz=Asia/Shanghai&from=2026-10-23&ignored=one';
  await get(path);
  await get(path);
  assert.equal(calls.length, 3);

  await get('/usage/summary?tz=UTC&from=2026-10-23&ignored=one');
  assert.equal(calls.length, 6);
  await get('/usage/summary?tz=Asia/Shanghai&from=2026-10-23&ignored=two');
  assert.equal(calls.length, 9);
  await get('/usage/summary?tz=Asia/Shanghai&from=2026-10-23&ignored=one&extra=1');
  assert.equal(calls.length, 12);

  now = new Date('2026-10-23T16:00:00Z');
  await get(path);
  assert.equal(calls.length, 15, 'UTC 日期未变但 Asia/Shanghai 本地日期已跨日，必须重算');
});

test('非 usage 路径和 400 错误响应不进入 usage 缓存', async (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  seed(ledger);
  const usageCalls = countCalls(ledger.read, ['totals']);
  const sessionCalls = countCalls(ledger.read, ['sessions', 'sourceStatus', 'modelPriceMarks']);
  const versionCalls = ledger.read.dataVersion ? countCalls(ledger.read, ['dataVersion']) : [];
  const get = harness(t, ledger);

  await get('/usage/summary?from=2026-10-24&to=2026-10-23&tz=UTC');
  await get('/usage/summary?from=2026-10-24&to=2026-10-23&tz=UTC');
  assert.equal(usageCalls.length, 0);
  assert.equal(versionCalls.length, 0);

  await get('/sessions?tz=UTC');
  await get('/sessions?tz=UTC');
  await get('/sources');
  await get('/sources');
  await get('/pricing');
  await get('/pricing');
  await get('/health');
  await get('/health');
  await get('/discovery');
  await get('/discovery');
  await get('/sync', 'POST');
  await get('/sync', 'POST');
  assert.deepEqual(sessionCalls, ['sessions', 'sessions', 'sourceStatus', 'sourceStatus', 'modelPriceMarks', 'modelPriceMarks']);
  assert.equal(versionCalls.length, 0);
});

test('64 条 LRU 缓存淘汰最久未使用项而不是最久未插入项', async (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  const calls = countCalls(ledger.read, ['timeseries']);
  const get = harness(t, ledger);
  const path = (n) => `/usage/unallocated?tz=UTC&case=${n}`;
  for (let n = 0; n < 64; n += 1) await get(path(n));
  assert.equal(calls.length, 64);

  await get(path(0));
  assert.equal(calls.length, 64);
  await get(path(64));
  assert.equal(calls.length, 65);
  await get(path(1));
  assert.equal(calls.length, 66, 'key 1 应作为最久未使用项被淘汰');
  await get(path(0));
  assert.equal(calls.length, 66, 'key 0 最近命中过，仍应保留');
});
