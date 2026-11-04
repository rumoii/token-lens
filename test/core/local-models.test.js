import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { openLedger, SCHEMA_VERSION } from '../../src/core/db/open.js';
import { LedgerWriter, payloadHash } from '../../src/core/db/write.js';
import { LedgerQueries } from '../../src/core/db/read.js';
import { priceRecord, costOf, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { CATALOG, versionOf } from '../../src/core/pricing/catalog.js';
import { buildPricing } from '../../src/core/api/v1/pricing.js';
import { buildBreakdown, buildSummary } from '../../src/core/api/v1/usage.js';
import { createRouter } from '../../src/core/api/router.js';

const record = (over = {}) => ({
  record_key: 'one', source: 'pi', session_id: 's', model: 'unlisted-local-model',
  kind: 'event', observed_at: '2026-10-26T01:00:00Z',
  input_tokens: 1000, output_tokens: 100, cache_read_tokens: 20, cache_write_tokens: 10,
  ...over
});

// Frozen v4 input order: provider must not add even a separator when unknown.
function v4Hash(r) {
  const known = v => v == null ? 'null' : Number(v);
  return createHash('sha256').update([
    r.kind || 'event', r.model || '',
    ...['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'].map(f => known(r[f])),
    r.observed_at || '', r.ended_at || '', r.session_id || '',
    ...['cache_write_5m_tokens', 'cache_write_1h_tokens'].map(f => known(r[f]))
  ].join('\x1f')).digest('hex').slice(0, 32);
}

function fixture(t) {
  const db = openLedger(':memory:');
  t.after(() => db.close());
  return { db, writer: new LedgerWriter(db), queries: new LedgerQueries(db) };
}

test('v4 → v5 只加 provider：所有既有字段逐行不变，重复打开不变', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-local-migrate-'));
  try {
    const path = join(dir, 'ledger.db');
    const old = new DatabaseSync(path);
    old.exec(`CREATE TABLE usage_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL UNIQUE,
      content_hash TEXT NOT NULL, source TEXT NOT NULL, session_id TEXT, project_key TEXT,
      model TEXT, observed_at TEXT NOT NULL, ended_at TEXT, kind TEXT NOT NULL,
      input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
      cache_write_5m_tokens INTEGER, cache_write_1h_tokens INTEGER,
      active INTEGER NOT NULL DEFAULT 1, revision INTEGER NOT NULL DEFAULT 1,
      superseded_by INTEGER REFERENCES usage_records(id), price_version TEXT, cost_micros INTEGER,
      price_source TEXT, ingested_at INTEGER NOT NULL DEFAULT (unixepoch()), source_file TEXT, parser_rev INTEGER
    ); PRAGMA user_version = 4;`);
    const insert = old.prepare(`INSERT INTO usage_records
      (record_key, content_hash, source, model, observed_at, kind, input_tokens, output_tokens,
       cache_read_tokens, cache_write_tokens, cost_micros, revision, active, price_version)
      VALUES (?, ?, 'pi', ?, '2026-10-26T01:00:00Z', ?, ?, ?, ?, ?, ?, ?, ?, 'old-price')`);
    insert.run('a', 'v4-hash-a', 'unlisted-local-model', 'event', 100, 20, 30, 40, null, 2, 1);
    insert.run('b', 'v4-hash-b', 'claude-opus-5-5', 'cumulative', 3, null, 5, 0, 1234, 7, 1);
    insert.run('c', 'v4-hash-c', null, 'event', null, 1, null, null, 0, 1, 0);
    const before = old.prepare('SELECT * FROM usage_records ORDER BY id').all().map(row => ({ ...row }));
    old.close();
    for (let i = 0; i < 2; i++) {
      const db = openLedger(path);
      try {
        assert.equal(SCHEMA_VERSION, 5);
        assert.equal(db.prepare('PRAGMA user_version').get().user_version, 5);
        const rows = db.prepare('SELECT * FROM usage_records ORDER BY id').all();
        assert.deepEqual(rows.map(({ provider, ...row }) => { assert.equal(provider, null); return row; }), before);
      } finally { db.close(); }
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('NULL provider 保留 v4 指纹；补 provider 只更新一次，移除也写回', t => {
  const { db, writer } = fixture(t);
  for (const r of [record(), record({ model: null, input_tokens: null, cache_write_1h_tokens: 0 })]) {
    assert.equal(payloadHash(r), v4Hash(r));
    assert.equal(payloadHash({ ...r, provider: null }), v4Hash(r));
  }
  const base = record();
  writer.ingestBatch([base], { priceOf: costOf });
  assert.equal(writer.ingestBatch([{ ...base, provider: null }], { priceOf: costOf }).unchanged, 1);
  assert.notEqual(payloadHash(base), payloadHash({ ...base, provider: 'ollama' }));
  assert.equal(writer.ingestBatch([{ ...base, provider: 'ollama' }], { priceOf: costOf }).updated, 1);
  assert.equal(writer.ingestBatch([{ ...base, provider: 'ollama' }], { priceOf: costOf }).unchanged, 1);
  assert.deepEqual({ ...db.prepare('SELECT revision, provider, cost_micros FROM usage_records').get() },
    { revision: 2, provider: 'ollama', cost_micros: 0 });
  assert.equal(writer.ingestBatch([base], { priceOf: costOf }).updated, 1);
  assert.equal(db.prepare('SELECT provider FROM usage_records').get().provider, null);
});

test('本地提供方大小写不敏感、优先于模型目录，四项全零；非本地按模型原价', () => {
  for (const provider of ['ollama', 'OlLaMa', 'lmstudio', 'LMStudio']) {
    for (const model of ['unlisted-local-model', 'claude-opus-5-5', null]) {
      const price = priceRecord(record({ provider, model, input_tokens: null }));
      assert.deepEqual(price, { cost_micros: 0, price_version: PRICE_VERSION,
        price_source: `local:${provider.toLowerCase()}`,
        parts: { input: 0, output: 0, cache_read: 0, cache_write: 0 } });
    }
  }
  const paid = record({ model: 'claude-opus-5-5' });
  assert.equal(priceRecord(paid).cost_micros, 6054);
  assert.deepEqual(priceRecord({ ...paid, provider: 'xiaomi-token-plan-cn' }), priceRecord(paid));
  for (const provider of [null, 'unknown-provider', 'ollama-cloud']) {
    assert.equal(priceRecord(record({ provider })).cost_micros, null);
  }
});

test('本地写入、总览未定价计数、分项核对和 reprice 一致，未知历史不猜 provider', t => {
  const { db, writer, queries } = fixture(t);
  writer.ingestBatch([record({ provider: 'ollama' }), record({ record_key: 'unknown' })], { priceOf: costOf });
  assert.equal(buildSummary(queries, {}).totals.unpriced_records, 1);
  const result = buildBreakdown(queries, { by: 'model' });
  assert.deepEqual(result.groups[0].cost_by_kind, {
    input: '0.000000', output: '0.000000', cache_read: '0.000000', cache_write: '0.000000'
  });
  assert.equal([...queries.costRows()][0].provider, 'ollama');
  const before = db.prepare('SELECT * FROM usage_records ORDER BY id').all();
  db.exec("UPDATE usage_records SET price_version = 'old', cost_micros = 123");
  assert.equal(writer.reprice(costOf, PRICE_VERSION), 2);
  assert.equal(writer.reprice(costOf, PRICE_VERSION), 0);
  assert.deepEqual(db.prepare('SELECT * FROM usage_records ORDER BY id').all(), before);
});

test('本地名单参与价格版本：仅名单变化也必须换版', () => {
  assert.notEqual(versionOf(CATALOG, ['ollama']), versionOf(CATALOG, ['ollama', 'lmstudio']));
  assert.equal(versionOf(CATALOG), PRICE_VERSION);
});

test('provider 必须是字符串或 NULL：非法类型拒绝入库，不让 SQLite 隐式转换', t => {
  const { db, writer } = fixture(t);
  const result = writer.ingestBatch([record({ provider: 123 })], { priceOf: costOf });
  assert.equal(result.rejected, 1);
  assert.equal(db.prepare('SELECT count(*) n FROM usage_records').get().n, 0);
});

test('价格路由表达本地与混合 provider，保留模型分组和标记总数，查询只读', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-26T12:00:00Z') });
  const { db, writer, queries } = fixture(t);
  writer.ingestBatch([
    record({ provider: 'ollama' }),
    record({ record_key: 'mixed-local', model: 'mixed', provider: 'LMStudio' }),
    record({ record_key: 'mixed-remote', model: 'mixed', provider: 'remote' }),
    record({ record_key: 'known-local', model: 'claude-opus-5-5', provider: 'ollama' }),
    record({ record_key: 'no-model', model: null, provider: 'ollama' })
  ], { priceOf: costOf });
  const before = db.prepare('SELECT * FROM usage_records').all();
  const router = createRouter({ queries,
    json: (_req, res, body) => Object.assign(res, { body: JSON.parse(JSON.stringify(body)) }) });
  const res = {};
  await router({ url: '/api/v1/pricing', method: 'GET' }, res, '/api/v1/pricing');
  const models = new Map(res.body.models.map(m => [m.model, m]));
  const local = models.get('unlisted-local-model');
  assert.equal(local.state, 'local');
  assert.equal(local.billing, 'local');
  assert.deepEqual(local.local_providers, { ollama: 1 });
  assert.equal(local.local_records, 1);
  assert.deepEqual(local.prices, { input: 0, output: 0, cache_read: 0, cache_write_5m: 0, cache_write_1h: 0 });
  assert.equal(models.get('claude-opus-5-5').state, 'local');
  assert.equal(models.get('claude-opus-5-5').tiers, null);
  assert.equal(models.get(null).state, 'local');
  assert.equal(models.get('mixed').state, 'unknown');
  assert.equal(models.get('mixed').local_records, 1);
  assert.deepEqual(models.get('mixed').local_providers, { lmstudio: 1 });
  assert.deepEqual(models.get('mixed').price_marks, { '': 2 });
  assert.deepEqual(res.body.counts, { verified: 0, aggregate: 0, unknown: 1, local: 3 });
  assert.deepEqual(db.prepare('SELECT * FROM usage_records').all(), before);
  assert.deepEqual(buildPricing(queries), res.body);
});
