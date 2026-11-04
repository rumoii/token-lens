import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseCopilot } from '../../src/core/adapters/copilot.js';

test('parseCopilot should extract events from assistant_usage_events table', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-copilot-'));
  const dbPath = join(tmp, 'session-store.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE assistant_usage_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      model TEXT NOT NULL,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      reasoning_tokens INTEGER,
      created_at TEXT
    );
  `);

  const insert = db.prepare(`
    INSERT INTO assistant_usage_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  insert.run(
    1,
    'copilot-sess-100',
    'claude-3-5-sonnet',
    4000,
    1000,
    1500,
    300,
    200,
    '2026-10-16T15:00:00.000Z'
  );
  db.close();

  const records = [];
  for await (const r of parseCopilot(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'copilot');
  assert.equal(records[0].session_id, 'copilot-sess-100');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 4000);
  // 1000 output + 200 reasoning = 1200
  assert.equal(records[0].output_tokens, 1200);
  assert.equal(records[0].cache_read_tokens, 1500);
  assert.equal(records[0].cache_creation_tokens, 300);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCopilot should fallback to sessions table in data.db', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-copilot-'));
  const dbPath = join(tmp, 'data.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      model TEXT,
      total_input_tokens INTEGER,
      total_output_tokens INTEGER,
      total_cached_tokens INTEGER,
      total_reasoning_tokens INTEGER,
      created_at TEXT,
      updated_at TEXT
    );
  `);

  const insert = db.prepare(`
    INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  insert.run(
    'copilot-app-1',
    'gpt-4o',
    8000,
    1500,
    2500,
    0,
    '2026-10-15T12:00:00.000Z',
    '2026-10-15T12:10:00.000Z'
  );
  db.close();

  const records = [];
  for await (const r of parseCopilot(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'copilot');
  assert.equal(records[0].session_id, 'copilot-app-1');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 8000);
  assert.equal(records[0].output_tokens, 1500);
  assert.equal(records[0].cache_read_tokens, 2500);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCopilot should ignore non-existent db gracefully', async () => {
  const empty = [];
  for await (const r of parseCopilot('non-existent-copilot.db')) {
    empty.push(r);
  }
  assert.equal(empty.length, 0);
});

test('C4 copilot events: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-copilot-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE assistant_usage_events (id TEXT, session_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, created_at TEXT)');
      db.prepare('INSERT INTO assistant_usage_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)').run(
        'm', 's', null, 10, 2, null, null, null, '2026-10-26T08:30:00.000Z'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseCopilot(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 copilot sessions: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-copilot-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE sessions (id TEXT, model TEXT, total_input_tokens INTEGER, total_output_tokens INTEGER, total_cached_tokens INTEGER, total_reasoning_tokens INTEGER, created_at TEXT, updated_at TEXT)');
      db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(
        's', null, 10, 2, null, null, '2026-10-26T08:30:00.000Z', '2026-10-26T08:30:00.000Z'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseCopilot(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
