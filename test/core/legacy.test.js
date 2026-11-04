import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Ledger } from '../../src/core/db/ledger.js';
import { importLegacy } from '../../src/core/db/legacy.js';

function makeOldDb(dir, { withTable = true } = {}) {
  const path = join(dir, 'data.db');
  const db = new DatabaseSync(path);
  if (withTable) {
    db.exec(`CREATE TABLE unified_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content_hash TEXT NOT NULL UNIQUE,
      source TEXT NOT NULL,
      session_id TEXT NOT NULL DEFAULT '',
      model TEXT NOT NULL DEFAULT 'unknown',
      timestamp TEXT NOT NULL,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
      estimated_cost REAL,
      created_at INTEGER
    )`);
    const ins = db.prepare(`INSERT INTO unified_records
      (content_hash, source, session_id, model, timestamp, input_tokens, output_tokens,
       cache_read_tokens, cache_creation_tokens, estimated_cost)
      VALUES (?,?,?,?,?,?,?,?,?,?)`);
    ins.run('h1', 'claude', 's1', 'claude-opus-4-1', '2026-10-10T01:00:00.000Z', 10, 5, 2, 1, 0.5);
    ins.run('h2', 'codex', 's2', 'gpt-6.1-sol', '2026-10-11T01:00:00.000Z', 20, 6, 0, 0, 0.1);
  } else {
    db.exec('CREATE TABLE something_else (id INTEGER)');
  }
  db.close();
  return path;
}

test('旧库只读导入：行数一致，旧库不被改动', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-legacy-'));
  try {
    const sourcePath = makeOldDb(dir);
    const ledger = new Ledger(join(dir, 'ledger.db'));

    const result = importLegacy({ ledger, sourceDbPath: sourcePath });
    assert.equal(result.available, true);
    assert.equal(result.imported, 2);
    assert.equal(ledger.read.legacyCount(), 2);

    // 旧库仍可独立打开且行数不变
    const check = new DatabaseSync(sourcePath, { readOnly: true });
    const count = check.prepare('SELECT count(*) AS c FROM unified_records').get();
    check.close();
    assert.equal(Number(count.c), 2);

    // 旧账不进入新账本统计
    assert.equal(ledger.read.totals().record_count, 0);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('旧库没有 unified_records 表：返回不可用，不抛错', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-legacy-'));
  try {
    const sourcePath = makeOldDb(dir, { withTable: false });
    const ledger = new Ledger(join(dir, 'ledger.db'));
    const result = importLegacy({ ledger, sourceDbPath: sourcePath });
    assert.equal(result.available, false);
    assert.match(result.reason, /unified_records/);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('旧库不存在：返回不可用', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-legacy-'));
  try {
    const ledger = new Ledger(join(dir, 'ledger.db'));
    const result = importLegacy({ ledger, sourceDbPath: join(dir, 'nope.db') });
    assert.equal(result.available, false);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('重复导入默认追加；replace=true 时先清空', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-legacy-'));
  try {
    const sourcePath = makeOldDb(dir);
    const ledger = new Ledger(join(dir, 'ledger.db'));
    importLegacy({ ledger, sourceDbPath: sourcePath });
    importLegacy({ ledger, sourceDbPath: sourcePath });
    assert.equal(ledger.read.legacyCount(), 4);
    importLegacy({ ledger, sourceDbPath: sourcePath, replace: true });
    assert.equal(ledger.read.legacyCount(), 2);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
