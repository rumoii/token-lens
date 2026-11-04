import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseHermes } from '../../src/core/adapters/hermes.js';

test('parseHermes should extract usage from session_model_usage table', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-hermes-'));
  const dbPath = join(tmp, 'state.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE session_model_usage (
      session_id TEXT,
      model TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      last_seen TEXT
    );
    CREATE TABLE sessions (
      id TEXT,
      cwd TEXT,
      title TEXT
    );
    INSERT INTO session_model_usage VALUES (
      'hermes-sess-001', 'deepseek-flash', 15000, 3200, 45000, 0, '2026-10-16T12:00:00.000Z'
    );
    INSERT INTO sessions VALUES (
      'hermes-sess-001', 'D:/work/project', 'test Hermes task'
    );
  `);
  db.close();

  const records = [];
  for await (const r of parseHermes(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'hermes');
  assert.equal(records[0].session_id, 'hermes-sess-001');
  assert.equal(records[0].model, 'deepseek-flash');
  assert.equal(records[0].input_tokens, 15000);
  assert.equal(records[0].output_tokens, 3200);
  assert.equal(records[0].cache_read_tokens, 45000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseHermes should fallback to sessions table when usage table is empty', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-hermes-'));
  const dbPath = join(tmp, 'state.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE sessions (
      id TEXT,
      model TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      last_activity_at TEXT
    );
    INSERT INTO sessions VALUES (
      'hermes-sess-fallback', 'claude-3-5-sonnet', 8000, 1200, 20000, 0, '2026-10-15T15:00:00.000Z'
    );
  `);
  db.close();

  const records = [];
  for await (const r of parseHermes(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'hermes');
  assert.equal(records[0].session_id, 'hermes-sess-fallback');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 8000);
  assert.equal(records[0].output_tokens, 1200);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseHermes should handle missing or empty database gracefully', async () => {
  const records = [];
  for await (const r of parseHermes('C:/non-existent-path/state.db')) {
    records.push(r);
  }
  assert.equal(records.length, 0);
});

test('C4 hermes session_model_usage: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-hermes-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'state.db'));
    try {
      db.exec('CREATE TABLE session_model_usage (session_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, last_seen TEXT)');
      db.prepare('INSERT INTO session_model_usage VALUES (?, ?, ?, ?, ?)').run(
        's', null, 10, 2, '2026-10-26T08:30:00.000Z'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseHermes(join(tmp, 'state.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
    assert.equal(records[0].record_key, 'hermes|s|hermes-agent', 'keep the existing unknown-model identity');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 hermes sessions: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-hermes-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'state.db'));
    try {
      db.exec('CREATE TABLE sessions (id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, last_activity_at TEXT)');
      db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?)').run(
        's', null, 10, 2, '2026-10-26T08:30:00.000Z'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseHermes(join(tmp, 'state.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
    assert.equal(records[0].record_key, 'hermes|s|hermes-agent', 'keep the existing unknown-model identity');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
