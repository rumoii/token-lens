import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { createRouter } from '../../src/core/api/router.js';

test('路由契约：用量、会话、来源、价格与错误形状保持一致', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-23T12:00:00Z') });
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'event', session_id: 'session', project_key: '/work/demo',
      model: 'claude-opus-5-5', observed_at: '2026-10-20T00:00:00Z', kind: 'event',
      input_tokens: 10, output_tokens: 5, cache_read_tokens: 2, cache_write_tokens: 0 },
    { source: 'dsh', record_key: 'snapshot', session_id: 'snapshot', model: null,
      observed_at: '2026-10-19T00:00:00Z', ended_at: '2026-10-21T00:00:00Z', kind: 'cumulative',
      input_tokens: 7, output_tokens: 3, cache_read_tokens: null, cache_write_tokens: null }
  ], { priceOf: (row) => row.model
    ? { cost_micros: 140, price_version: 'test', price_source: 'test' } : null });
  const router = createRouter({ queries: ledger.read, meta: {
    version: 'test', port: 3456, dataDir: '/test-data', ledgerPath: '/test-data/ledger.db', schemaVersion: 3
  }, json: (_req, res, body, status = 200) => Object.assign(res, { body, status }), runSync: async () => null });
  const get = async (path, method = 'GET') => {
    const res = {};
    const url = `/api/v1${path}`;
    assert.equal(await router({ url, method }, res, new URL(url, 'http://localhost').pathname), true);
    return res;
  };
  const summary = (await get('/usage/summary?tz=UTC')).body;
  assert.deepEqual(summary.totals, {
    gross_tokens: 27, input_tokens: 17, output_tokens: 8, cache_read_tokens: 2,
    cache_write_tokens: 0, cost_usd: '0.000140', unpriced_records: 1, record_count: 2
  });
  assert.equal(summary.snapshot.generated_at, '2026-10-23T12:00:00.000Z');
  assert.equal(summary.activity.sessions, 2);
  const series = (await get('/usage/timeseries?tz=UTC')).body;
  assert.equal(series.points[0].gross_tokens, 17);
  assert.equal(series.unallocated.gross_tokens, 10);
  assert.equal((await get('/usage/unallocated?tz=UTC')).body.unallocated.gross_tokens, 10);
  const matrix = (await get('/usage/matrix?by=source&tz=UTC')).body;
  assert.equal(matrix.rows[0].key, 'claude');
  assert.equal(matrix.rows[0].gross_tokens + matrix.unallocated.gross_tokens, 27);
  const breakdown = (await get('/usage/breakdown?by=source&tz=UTC')).body;
  assert.equal(breakdown.groups.reduce((sum, row) => sum + row.gross_tokens, 0), 27);
  assert.equal((await get('/usage/summary?source=claude&tz=UTC')).body.totals.gross_tokens, 17);
  const sessions = (await get('/sessions?limit=1&tz=UTC')).body;
  assert.equal(sessions.items.length, 1);
  assert.ok(sessions.next_cursor);
  assert.equal((await get(`/sessions?limit=1&cursor=${encodeURIComponent(sessions.next_cursor)}&tz=UTC`)).body.items.length, 1);
  const detail = (await get('/sessions/detail?source=claude&session_id=session&tz=UTC')).body;
  assert.equal(detail.session.project_key, '/work/demo');
  assert.deepEqual(detail.kinds, { event: 1, cumulative: 0 });
  assert.equal((await get('/sources')).body.sources.length, 2);
  assert.deepEqual((await get('/pricing')).body.counts, { verified: 1, aggregate: 0, unknown: 1, local: 0 });
  assert.deepEqual((await get('/health')).body, {
    ok: true, version: 'test', port: 3456, data_dir: '/test-data', db: { path: '/test-data/ledger.db', schema_version: 3 }
  });
  assert.deepEqual(await get('/sessions/detail'), { status: 400,
    body: { error: { code: 'invalid_param', message: '需要同时给出 source 与 session_id' } } });
  assert.equal((await get('/sessions/detail?source=claude&session_id=missing')).status, 404);
  assert.equal((await get('/missing')).status, 404);
  assert.equal((await get('/sync', 'POST')).status, 409);
  assert.equal((await get('/pricing/refresh', 'POST')).status, 501);
});

test('路由契约：from 晚于 to 的区间报 invalid_range', async (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  const router = createRouter({ queries: ledger.read, meta: {
    version: 'test', port: 3456, dataDir: '/test-data', ledgerPath: '/test-data/ledger.db', schemaVersion: 3
  }, json: (_req, res, body, status = 200) => Object.assign(res, { body, status }), runSync: async () => null });
  const res = {};
  const url = '/api/v1/usage/summary?from=2026-10-02&to=2026-10-01';
  assert.equal(await router({ url, method: 'GET' }, res, '/api/v1/usage/summary'), true);
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'invalid_range');
});

test('路由实例各自持有发现缓存，不把扫描文件路径传给页面', async () => {
  let calls = 0;
  const ctx = {
    discover: () => ({ codex: Array(++calls).fill('/private/session.jsonl') }),
    json: (_req, res, body) => { res.body = body; }
  };
  const first = createRouter(ctx);
  const second = createRouter(ctx);
  const discover = async (router) => {
    const res = {};
    await router({ url: '/api/v1/discovery', method: 'GET' }, res, '/api/v1/discovery');
    assert.equal(JSON.stringify(res.body).includes('/private/'), false);
    return res.body.sources[0].files;
  };
  assert.equal(await discover(first), 1);
  assert.equal(await discover(second), 2);
  assert.equal(await discover(first), 1);
});
