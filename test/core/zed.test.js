import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { zstdCompressSync } from 'node:zlib';
import { parseZed } from '../../src/core/adapters/zed.js';

test('parseZed should extract request_token_usage from raw json threads.db', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-zed-'));
  const dbPath = join(tmp, 'threads.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      updated_at TEXT NOT NULL,
      data_type TEXT NOT NULL,
      data BLOB NOT NULL
    );
  `);

  const mockThread = {
    version: '0.3.0',
    title: 'refactor database layer',
    updated_at: '2026-05-01T12:00:00.000Z',
    model: { provider: 'anthropic', model: 'claude-3-5-sonnet' },
    imported: false,
    request_token_usage: {
      round_1: { input_tokens: 1500, output_tokens: 300, cache_read_input_tokens: 500, cache_creation_input_tokens: 100 },
      round_2: { input_tokens: 2000, output_tokens: 500, cache_read_input_tokens: 800, cache_creation_input_tokens: 0 }
    }
  };

  const jsonBytes = Buffer.from(JSON.stringify(mockThread), 'utf8');
  const insert = db.prepare('INSERT INTO threads VALUES (?, ?, ?, ?)');
  insert.run('zed-thread-001', '2026-05-01T12:00:00.000Z', 'json', jsonBytes);
  db.close();

  const records = [];
  for await (const r of parseZed(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'zed');
  assert.equal(records[0].session_id, 'zed-thread-001');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 3500); // 1500 + 2000
  assert.equal(records[0].output_tokens, 800);  // 300 + 500
  assert.equal(records[0].cache_read_tokens, 1300); // 500 + 800
  assert.equal(records[0].cache_creation_tokens, 100);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseZed should decompress zstd blob and fallback to cumulative_token_usage', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-zed-'));
  const dbPath = join(tmp, 'threads.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      updated_at TEXT NOT NULL,
      data_type TEXT NOT NULL,
      data BLOB NOT NULL
    );
  `);

  const mockThread = {
    version: '0.3.0',
    title: 'zstd thread test',
    updated_at: '2026-05-02T10:00:00.000Z',
    model: 'gpt-4o',
    cumulative_token_usage: {
      input_tokens: 8000,
      output_tokens: 1200,
      cached_input_tokens: 3000
    }
  };

  const rawBytes = Buffer.from(JSON.stringify(mockThread), 'utf8');
  const zstdCompressed = zstdCompressSync(rawBytes);

  const insert = db.prepare('INSERT INTO threads VALUES (?, ?, ?, ?)');
  insert.run('zed-thread-zstd', '2026-05-02T10:00:00.000Z', 'zstd', Buffer.from(zstdCompressed));
  db.close();

  const records = [];
  for await (const r of parseZed(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'zed');
  assert.equal(records[0].session_id, 'zed-thread-zstd');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 8000);
  assert.equal(records[0].output_tokens, 1200);
  assert.equal(records[0].cache_read_tokens, 3000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseZed should skip imported threads and handle non-existent db gracefully', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-zed-'));
  const dbPath = join(tmp, 'threads.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at TEXT, data_type TEXT, data BLOB);
  `);

  const importedThread = {
    imported: true,
    request_token_usage: { r1: { input_tokens: 100 } }
  };

  const insert = db.prepare('INSERT INTO threads VALUES (?, ?, ?, ?)');
  insert.run('imported-id', '2026-05-01', 'json', Buffer.from(JSON.stringify(importedThread)));
  db.close();

  const records = [];
  for await (const r of parseZed(dbPath)) {
    records.push(r);
  }
  assert.equal(records.length, 0);

  // Non-existent path
  const empty = [];
  for await (const r of parseZed('non-existent.db')) {
    empty.push(r);
  }
  assert.equal(empty.length, 0);

  rmSync(tmp, { recursive: true, force: true });
});

test('C4 zed thread: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-zed-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE threads (id TEXT, updated_at TEXT, data_type TEXT, data BLOB)');
      db.prepare('INSERT INTO threads VALUES (?, ?, ?, ?)').run(
        's', '2026-10-26T08:30:00.000Z', 'json', '{"cumulative_token_usage":{"input_tokens":10,"output_tokens":2}}'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseZed(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
