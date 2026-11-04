import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseGoose } from '../../src/core/adapters/goose.js';

test('parseGoose should extract accumulated tokens without classifying the total remainder', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-goose-'));
  const dbPath = join(tmp, 'sessions.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      model_config_json TEXT,
      provider_name TEXT,
      created_at TEXT NOT NULL,
      total_tokens INTEGER,
      input_tokens INTEGER,
      output_tokens INTEGER,
      accumulated_total_tokens INTEGER,
      accumulated_input_tokens INTEGER,
      accumulated_output_tokens INTEGER
    );
  `);

  const insert = db.prepare(`
    INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  insert.run(
    'goose-sess-001',
    JSON.stringify({ model_name: 'claude-3-7-sonnet' }),
    'anthropic',
    '2026-05-21T14:00:00.000Z',
    100,
    80,
    20,
    5000,
    4000,
    800
  );
  db.close();

  const records = [];
  for await (const r of parseGoose(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'goose');
  assert.equal(records[0].session_id, 'goose-sess-001');
  assert.equal(records[0].model, 'claude-3-7-sonnet');
  assert.equal(records[0].input_tokens, 4000);
  // total 的 200 余量分类未知，只计明确上报的 output。
  assert.equal(records[0].output_tokens, 800);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseGoose should gracefully handle legacy schema without accumulated columns', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-goose-'));
  const dbPath = join(tmp, 'sessions.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      model_config_json TEXT,
      provider_name TEXT,
      created_at TEXT NOT NULL,
      total_tokens INTEGER,
      input_tokens INTEGER,
      output_tokens INTEGER
    );
  `);

  const insert = db.prepare(`
    INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  insert.run(
    'goose-sess-legacy',
    JSON.stringify({ model_name: 'gpt-4o' }),
    'openai',
    '2026-05-21 14:30:00',
    1000,
    800,
    200
  );
  db.close();

  const records = [];
  for await (const r of parseGoose(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'goose');
  assert.equal(records[0].session_id, 'goose-sess-legacy');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 800);
  assert.equal(records[0].output_tokens, 200);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseGoose should ignore non-existent db gracefully', async () => {
  const records = [];
  for await (const r of parseGoose('non-existent-goose.db')) {
    records.push(r);
  }
  assert.equal(records.length, 0);
});

test('C4 goose no-config: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-goose-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE sessions (id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER)');
      db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)').run(
        's', null, 'provider-is-not-a-model', '2026-10-26T08:30:00.000Z', 10, 2, 12
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseGoose(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 goose config-without-model: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-goose-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE sessions (id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER)');
      db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)').run(
        's', '{}', 'provider-is-not-a-model', '2026-10-26T08:30:00.000Z', 10, 2, 12
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseGoose(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 goose invalid-config: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-goose-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE sessions (id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER)');
      db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)').run(
        's', '{', 'provider-is-not-a-model', '2026-10-26T08:30:00.000Z', 10, 2, 12
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseGoose(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
