import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { costOf } from '../../src/core/pricing/engine.js';
import { parseClaude } from '../../src/core/adapters/claude.js';
import { openLedger, SCHEMA_VERSION } from '../../src/core/db/open.js';

/**
 * 构造一条 Claude 日志行。
 *
 * @param {Object} usage
 * @param {string} [id]
 * @returns {string}
 */
function claudeLine(usage, id = 'msg_1') {
  return JSON.stringify({
    type: 'assistant',
    sessionId: 'sess-1',
    timestamp: '2026-10-18T00:00:00.000Z',
    cwd: 'D:\\work\\demo',
    message: { id, model: 'claude-opus-5-5', usage }
  });
}

test('缓存写分档：1 小时档按 1 小时单价', () => {
  const price = costOf({
    model: 'claude-opus-5-5',
    input_tokens: 0, output_tokens: 0, cache_read_tokens: 0,
    cache_write_tokens: 1000,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 1000
  });
  assert.equal(price.cost_micros, 8000, '1000 token × 8.00/M');
});

test('缓存写分档：5 分钟档按 5 分钟单价', () => {
  const price = costOf({
    model: 'claude-opus-5-5',
    input_tokens: 0, output_tokens: 0, cache_read_tokens: 0,
    cache_write_tokens: 1000,
    cache_write_5m_tokens: 1000,
    cache_write_1h_tokens: 0
  });
  assert.equal(price.cost_micros, 5000, '1000 token × 5.00/M');
});

test('缓存写分档：两档混合各自计价', () => {
  const price = costOf({
    model: 'claude-opus-5-5',
    input_tokens: 0, output_tokens: 0, cache_read_tokens: 0,
    cache_write_tokens: 1000,
    cache_write_5m_tokens: 400,
    cache_write_1h_tokens: 600
  });
  assert.equal(price.cost_micros, 6800, '400×5 + 600×8');
});

test('缓存写分档缺失时回落到 5 分钟单价', () => {
  const price = costOf({
    model: 'claude-opus-5-5',
    input_tokens: 0, output_tokens: 0, cache_read_tokens: 0,
    cache_write_tokens: 1000,
    cache_write_5m_tokens: null,
    cache_write_1h_tokens: null
  });
  assert.equal(price.cost_micros, 5000, '分档未知不猜，与分档引入前一致');
});

test('分档齐全且自洽时适配器输出两档', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-split-'));
  const file = join(dir, 'session.jsonl');
  writeFileSync(file, claudeLine({
    input_tokens: 2,
    output_tokens: 10,
    cache_read_input_tokens: 100,
    cache_creation_input_tokens: 50,
    cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 50 }
  }), 'utf8');

  const records = [];
  for await (const r of parseClaude(file)) records.push(r);

  assert.equal(records.length, 1);
  assert.equal(records[0].cache_write_tokens, 50);
  assert.equal(records[0].cache_write_5m_tokens, 0);
  assert.equal(records[0].cache_write_1h_tokens, 50);

  rmSync(dir, { recursive: true, force: true });
});

test('分档之和与合计不符时只报合计', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-split-'));
  const file = join(dir, 'session.jsonl');
  writeFileSync(file, claudeLine({
    input_tokens: 2,
    output_tokens: 10,
    cache_read_input_tokens: 100,
    cache_creation_input_tokens: 50,
    cache_creation: { ephemeral_5m_input_tokens: 10, ephemeral_1h_input_tokens: 10 }
  }), 'utf8');

  const records = [];
  for await (const r of parseClaude(file)) records.push(r);

  assert.equal(records[0].cache_write_tokens, 50, '合计照报');
  assert.equal(records[0].cache_write_5m_tokens, undefined, '不自洽就不报分档');
  assert.equal(records[0].cache_write_1h_tokens, undefined);

  rmSync(dir, { recursive: true, force: true });
});

test('缺少 cache_creation 分档时只报合计', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-split-'));
  const file = join(dir, 'session.jsonl');
  writeFileSync(file, claudeLine({
    input_tokens: 2,
    output_tokens: 10,
    cache_read_input_tokens: 100,
    cache_creation_input_tokens: 50
  }), 'utf8');

  const records = [];
  for await (const r of parseClaude(file)) records.push(r);

  assert.equal(records[0].cache_write_tokens, 50);
  assert.equal(records[0].cache_write_5m_tokens, undefined);

  rmSync(dir, { recursive: true, force: true });
});

test('v1 账本升到当前版本：加列、行数不变、旧行分档为空', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-migrate-'));
  const dbPath = join(dir, 'ledger.db');

  // 造一个 v1 结构（没有分档两列）
  const v1 = new DatabaseSync(dbPath);
  v1.exec(`
    CREATE TABLE usage_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      record_key TEXT NOT NULL UNIQUE,
      content_hash TEXT NOT NULL,
      source TEXT NOT NULL,
      session_id TEXT,
      project_key TEXT,
      model TEXT,
      observed_at TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('event','cumulative')),
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      active INTEGER NOT NULL DEFAULT 1,
      revision INTEGER NOT NULL DEFAULT 1,
      superseded_by INTEGER REFERENCES usage_records(id),
      price_version TEXT,
      cost_micros INTEGER,
      price_source TEXT,
      ingested_at INTEGER NOT NULL DEFAULT (unixepoch())
    );
  `);
  v1.prepare(`
    INSERT INTO usage_records
      (record_key, content_hash, source, model, observed_at, kind,
       input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_micros)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)
  `).run('claude|s|msg_1', 'h1', 'claude', 'claude-opus-5-5',
    '2026-10-10T00:00:00.000Z', 'event', 2, 10, 100, 50, 12345);
  v1.exec('PRAGMA user_version = 1');
  v1.close();

  const db = openLedger(dbPath);
  const version = Number(db.prepare('PRAGMA user_version').get()?.user_version);
  const columns = db.prepare('PRAGMA table_info(usage_records)').all().map((r) => r.name);
  const row = db.prepare(`
    SELECT input_tokens, cache_write_tokens, cache_write_5m_tokens, cache_write_1h_tokens, cost_micros
    FROM usage_records WHERE record_key = 'claude|s|msg_1'
  `).get();

  assert.equal(version, SCHEMA_VERSION);
  assert.equal(version, 5);
  assert.ok(columns.includes('cache_write_5m_tokens'));
  assert.ok(columns.includes('ended_at'), '一路升到 v3');
  assert.ok(columns.includes('cache_write_1h_tokens'));
  assert.equal(row.input_tokens, 2, '旧数据可读');
  assert.equal(row.cache_write_tokens, 50);
  assert.equal(row.cache_write_5m_tokens, null, '历史分档未知，不回填');
  assert.equal(row.cache_write_1h_tokens, null);
  assert.equal(row.cost_micros, 12345, '迁移不动金额');

  db.close();
  rmSync(dir, { recursive: true, force: true });
});
