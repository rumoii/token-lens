import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseOpencode } from '../../src/core/adapters/opencode.js';
import { PARSER_REV } from '../../src/core/adapters/index.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';
import { costOf } from '../../src/core/pricing/engine.js';

function projectFixture(t, version) {
  const root = mkdtempSync(join(tmpdir(), 'tl-opencode-project-'));
  const file = join(root, 'opencode.db');
  const db = new DatabaseSync(file);
  t.after(() => {
    db.close();
    rmSync(root, { recursive: true, force: true });
  });
  const table = version === 'v2' ? 'session_message' : 'message';
  const sessionTable = version === 'v2' ? 'session_v2' : 'session';
  db.exec(`
    CREATE TABLE ${table} (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_updated INTEGER, time_created INTEGER, data TEXT);
    CREATE TABLE ${sessionTable} (id TEXT PRIMARY KEY, directory TEXT);
  `);
  const put = (id, session) => db.prepare(`INSERT INTO ${table} VALUES (?, ?, ?, ?, ?, ?)`).run(
    id, session, 'assistant', 1792960000000, 1792960000000, JSON.stringify({
      role: 'assistant', type: 'assistant', modelID: 'claude-opus-5-5',
      tokens: { input: 100, output: 20, cache: { read: 5, write: 1 } },
      sessionID: 'wrong', directory: '/not-the-session', cwd: '/not-the-session'
    })
  );
  const parse = () => Array.fromAsync(parseOpencode(file));
  return { db, file, sessionTable, put, parse };
}

for (const version of ['v1', 'v2']) {
  test(`opencode ${version} projects: match directories across sessions and ignore the other version's table`, async (t) => {
    const f = projectFixture(t, version);
    const other = version === 'v2' ? 'session' : 'session_v2';
    f.db.exec(`CREATE TABLE ${other} (id TEXT PRIMARY KEY, directory TEXT)`);
    const directories = ['D:/work/one/', '/srv/two/', '', '   ', null];
    for (const [i, directory] of directories.entries()) {
      f.db.prepare(`INSERT INTO ${f.sessionTable} VALUES (?, ?)`).run(`s${i}`, directory);
      f.db.prepare(`INSERT INTO ${other} VALUES (?, ?)`).run(`s${i}`, '/wrong-version');
      f.put(`m${i}`, `s${i}`);
    }
    f.db.prepare(`INSERT INTO ${other} VALUES (?, ?)`).run('absent', '/wrong-version');
    f.put('orphan', 'absent');
    const rows = await f.parse();
    assert.deepEqual(rows.map(row => [row.session_id, row.project_key]), [
      ['s0', 'D:\\work\\one'], ['s1', '/srv/two'], ['s2', null], ['s3', null], ['s4', null], ['absent', null]
    ]);
  });

  test(`opencode ${version} projects: missing table or column keeps usage with NULL project`, async (t) => {
    const f = projectFixture(t, version);
    f.put('m', 's');
    f.db.exec(`DROP TABLE ${f.sessionTable}; CREATE TABLE ${f.sessionTable} (id TEXT PRIMARY KEY, project_id TEXT)`);
    f.db.prepare(`INSERT INTO ${f.sessionTable} VALUES (?, ?)`).run('s', '/not-a-directory-field');
    assert.equal((await f.parse())[0].project_key, null);
    f.db.exec(`DROP TABLE ${f.sessionTable}`);
    const [row] = await f.parse();
    assert.equal(row.project_key, null);
    assert.equal(row.input_tokens, 100);
  });

  test(`opencode ${version} projects: parser upgrade relabels without revising usage or prices`, async (t) => {
    const f = projectFixture(t, version);
    f.put('m1', 's1');
    f.put('m2', 's2');
    const ledgerDb = openLedger(':memory:');
    t.after(() => ledgerDb.close());
    const writer = new LedgerWriter(ledgerDb);
    const snapshot = () => ledgerDb.prepare('SELECT * FROM usage_records ORDER BY record_key').all().map(row => ({ ...row }));
    assert.equal(writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: 5 }).inserted, 2);
    const before = snapshot();
    assert.ok(before.every(row => row.project_key === null && row.revision === 1 && row.cost_micros > 0));
    f.db.exec(`INSERT INTO ${f.sessionTable} VALUES ('s1', 'D:/work/one/'), ('s2', '/srv/two/')`);
    const result = writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.opencode });
    assert.equal(result.counts.relabeled, 2);
    assert.equal(PARSER_REV.opencode, 6);
    assert.equal(result.updated, 0);
    assert.equal(result.inserted, 0);
    const expected = before.map((row, i) => ({ ...row, project_key: ['D:\\work\\one', '/srv/two'][i], parser_rev: 6 }));
    assert.deepEqual(snapshot(), expected, 'only project_key and parser_rev may change');
    const again = writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.opencode });
    assert.equal(again.counts.relabeled, 0);
    assert.equal(again.unchanged, 2);
    assert.deepEqual(snapshot(), expected);
  });
}

test('opencode projects: empty v2 messages fall back to the v1 session directory', async (t) => {
  const f = projectFixture(t, 'v1');
  f.db.exec(`
    CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_updated INTEGER, time_created INTEGER, data TEXT);
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT);
    INSERT INTO session_v2 VALUES ('s', '/wrong-version');
    INSERT INTO session VALUES ('s', '/srv/v1');
  `);
  f.put('m', 's');
  assert.equal((await f.parse())[0].project_key, '/srv/v1');
});

test('parseOpencode should parse v2 session_message table records', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-opencode-'));
  const dbPath = join(tmp, 'opencode.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      type TEXT NOT NULL,
      seq INTEGER NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
  `);

  const mockV2Msg = {
    id: 'msg_v2_101',
    sessionID: 'ses_v2_alpha',
    type: 'assistant',
    model: { id: 'deepseek-coder-v2', providerID: 'deepseek' },
    time: { created: 1784357000000, completed: 1784357005000 },
    tokens: {
      input: 5000,
      output: 1200,
      reasoning: 300,
      cache: { read: 2000, write: 500 }
    }
  };

  const insert = db.prepare('INSERT INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)');
  insert.run(
    'msg_v2_101',
    'ses_v2_alpha',
    'assistant',
    1,
    1784357000000,
    1784357005000,
    JSON.stringify(mockV2Msg)
  );
  db.close();

  const records = [];
  for await (const r of parseOpencode(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'opencode');
  assert.equal(records[0].session_id, 'ses_v2_alpha');
  assert.equal(records[0].model, 'deepseek-coder-v2');
  assert.equal(records[0].input_tokens, 5000);
  assert.equal(records[0].output_tokens, 1500); // 1200 output + 300 reasoning
  assert.equal(records[0].cache_read_tokens, 2000);
  assert.equal(records[0].cache_creation_tokens, 500);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseOpencode should fallback to v1 message table records', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-opencode-'));
  const dbPath = join(tmp, 'opencode.db');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE message (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
  `);

  const mockV1Msg = {
    id: 'msg_v1_001',
    sessionID: 'ses_v1_beta',
    role: 'assistant',
    modelID: 'claude-3-5-sonnet',
    tokens: {
      input: 3000,
      output: 800,
      cache: { read: 1000, write: 0 }
    }
  };

  const insert = db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?)');
  insert.run(
    'msg_v1_001',
    'ses_v1_beta',
    1784356000000,
    1784356005000,
    JSON.stringify(mockV1Msg)
  );
  db.close();

  const records = [];
  for await (const r of parseOpencode(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'opencode');
  assert.equal(records[0].session_id, 'ses_v1_beta');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 3000);
  assert.equal(records[0].output_tokens, 800);
  assert.equal(records[0].cache_read_tokens, 1000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseOpencode should gracefully handle non-existent db', async () => {
  const records = [];
  for await (const r of parseOpencode('non-existent-opencode.db')) {
    records.push(r);
  }
  assert.equal(records.length, 0);
});

test('C4 opencode message: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-opencode-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE message (id TEXT, session_id TEXT, type TEXT, time_updated INTEGER, time_created INTEGER, data TEXT)');
      db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?, ?)').run(
        'm', 's', 'assistant', 1792960000000, 1792960000000, '{"type":"assistant","tokens":{"input":10,"output":2}}'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseOpencode(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 opencode session_message: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-opencode-nomodel-'));
  try {
    const db = new DatabaseSync(join(tmp, 'usage.db'));
    try {
      db.exec('CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_updated INTEGER, time_created INTEGER, data TEXT)');
      db.prepare('INSERT INTO session_message VALUES (?, ?, ?, ?, ?, ?)').run(
        'm', 's', 'assistant', 1792960000000, 1792960000000, '{"type":"assistant","tokens":{"input":10,"output":2}}'
      );
    } finally {
      db.close();
    }
    const records = [];
    for await (const record of parseOpencode(join(tmp, 'usage.db'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
