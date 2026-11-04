import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { discoverAll } from '../../src/core/discovery.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';
import { costOf } from '../../src/core/pricing/engine.js';

const created = 1792960000000;
// Kilo 21bcdec484a0: session/sql.ts and schema/session-message.ts.
const assistant = (fields = {}) => ({
  agent: 'build', model: { id: 'claude-opus-5-5', providerID: 'anthropic' }, content: [],
  time: { created, completed: created + 5000 },
  tokens: { input: 100, output: 20, reasoning: 5, cache: { read: 30, write: 10 } },
  ...fields
});

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'tl-kilo-'));
  const file = join(root, 'kilo.db');
  const db = new DatabaseSync(file);
  const ledger = new Ledger(':memory:');
  t.after(() => {
    try { ledger.close(); } finally {
      try { db.close(); } finally { rmSync(root, { recursive: true, force: true }); }
    }
  });
  db.exec(`
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
    CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message(session_id, seq);
    CREATE TABLE session (
      id TEXT PRIMARY KEY, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
      tokens_cache_read INTEGER, tokens_cache_write INTEGER
    );
    CREATE TABLE message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL
    );
    CREATE TABLE part (
      id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT
    );
  `);
  const put = (id = 'msg_1', data = assistant(), { session = 'ses_1', type = 'assistant', time = created } = {}) => {
    db.prepare('INSERT OR REPLACE INTO session_message VALUES (?, ?, ?, NULL, ?, ?, ?)').run(
      id, session, type, time, created + 9000, typeof data === 'string' ? data : JSON.stringify(data)
    );
  };
  const parse = async (path = file, notes) => {
    assert.equal(typeof adapters.kilo, 'function', 'kilo parser must be registered');
    return Array.fromAsync(adapters.kilo(path, notes));
  };
  const ingest = async (path = file, notes) => ledger.write.ingestBatch(await parse(path, notes), {
    priceOf: costOf, sourceFile: path, parserRev: PARSER_REV.kilo
  });
  return { root, file, db, ledger, put, parse, ingest };
}

test('kilo normal: exclusive input, stable IDs and message creation time', async (t) => {
  const f = fixture(t);
  f.put();
  f.put('msg_user', assistant(), { type: 'user' });
  const [row] = await f.parse();
  assert.equal((await f.parse()).length, 1);
  assert.equal(PARSER_REV.kilo, 3);
  assert.deepEqual(row, {
    record_key: 'kilo|ses_1|msg_1', source: 'kilo', session_id: 'ses_1', project_key: null,
    model: 'claude-opus-5-5', provider: 'anthropic', observed_at: '2026-10-25T20:26:40.000Z', kind: 'event',
    input_tokens: 100, output_tokens: 25, cache_read_tokens: 30, cache_write_tokens: 10
  });
});

test('kilo repeat collection: row count, tokens and cost stay unchanged', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  const before = f.ledger.read.totals();
  assert.ok(before.cost_micros > 0);
  const again = await f.ingest();
  assert.equal(again.inserted, 0);
  assert.equal(again.unchanged, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('kilo projects: associate each message with its session directory', async (t) => {
  const f = fixture(t);
  f.db.exec('ALTER TABLE session ADD COLUMN directory TEXT');
  const directories = ['D:/work/one/', '/srv/two/', '', '   ', null];
  const insert = f.db.prepare('INSERT INTO session (id, directory) VALUES (?, ?)');
  for (const [i, directory] of directories.entries()) {
    insert.run(`ses_${i}`, directory);
    f.put(`msg_${i}`, assistant({ directory: '/not-the-session', sessionID: 'wrong' }), { session: `ses_${i}` });
  }
  f.put('orphan', assistant({ cwd: '/not-reported-by-session' }), { session: 'absent' });
  const rows = await f.parse();
  assert.deepEqual(rows.map(row => [row.session_id, row.project_key]), [
    ['ses_0', 'D:\\work\\one'], ['ses_1', '/srv/two'],
    ['ses_2', null], ['ses_3', null], ['ses_4', null], ['absent', null]
  ]);
});

test('kilo projects: missing session table or directory column keeps usage with NULL project', async (t) => {
  const f = fixture(t);
  f.put();
  f.db.exec("INSERT INTO session (id) VALUES ('ses_1')");
  assert.equal((await f.parse())[0].project_key, null);
  f.db.exec('DROP TABLE session');
  const [row] = await f.parse();
  assert.equal(row.project_key, null);
  assert.equal(row.input_tokens, 100);
});

test('kilo projects: parser upgrade relabels real ledger rows without revising usage or prices', async (t) => {
  const f = fixture(t);
  f.put('msg_1', assistant(), { session: 'ses_1' });
  f.put('msg_2', assistant(), { session: 'ses_2' });
  const ledgerDb = openLedger(':memory:');
  t.after(() => ledgerDb.close());
  const writer = new LedgerWriter(ledgerDb);
  const snapshot = () => ledgerDb.prepare('SELECT * FROM usage_records ORDER BY record_key').all().map(row => ({ ...row }));
  assert.equal(writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: 2 }).inserted, 2);
  const before = snapshot();
  assert.ok(before.every(row => row.project_key === null && row.revision === 1 && row.cost_micros > 0));
  f.db.exec(`
    ALTER TABLE session ADD COLUMN directory TEXT;
    INSERT INTO session (id, directory) VALUES ('ses_1', 'D:/work/one/'), ('ses_2', '/srv/two/');
  `);
  const result = writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.kilo });
  assert.equal(result.counts.relabeled, 2);
  assert.equal(PARSER_REV.kilo, 3);
  assert.equal(result.updated, 0);
  assert.equal(result.inserted, 0);
  const expected = before.map((row, i) => ({ ...row, project_key: ['D:\\work\\one', '/srv/two'][i], parser_rev: 3 }));
  assert.deepEqual(snapshot(), expected, 'only project_key and parser_rev may change');
  const again = writer.ingestBatch(await f.parse(), { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.kilo });
  assert.equal(again.counts.relabeled, 0);
  assert.equal(again.unchanged, 2);
  assert.deepEqual(snapshot(), expected);
});

test('kilo growth: update the same event and append only a new message', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  f.put('msg_1', assistant({ tokens: { input: 200, output: 40, reasoning: 10 } }));
  const growth = await f.ingest();
  assert.equal(growth.updated, 1);
  assert.equal(growth.inserted, 0);
  assert.equal(f.ledger.read.totals().record_count, 1);
  assert.equal(f.ledger.read.totals().input_tokens, 200);
  assert.equal(f.ledger.read.totals().output_tokens, 50);
  f.put('msg_2');
  const append = await f.ingest();
  assert.equal(append.inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
});

test('kilo snapshot change: overwrite message usage, ignore cumulative session totals', async (t) => {
  const f = fixture(t);
  f.put();
  f.db.exec("INSERT INTO session VALUES ('ses_1', 100, 20, 5, 30, 10)");
  await f.ingest();
  f.put('msg_1', assistant({ tokens: { input: 70, output: 10, reasoning: 2, cache: { read: 8, write: 3 } } }));
  f.db.exec('UPDATE session SET tokens_input = 900000, tokens_output = 900000');
  const changed = await f.ingest();
  assert.equal(changed.updated, 1);
  const total = f.ledger.read.totals();
  assert.equal(total.record_count, 1);
  assert.equal(total.gross_tokens, 93);
  assert.ok((await f.parse()).every(row => row.kind === 'event'));
});

test('kilo rotation and truncation: copied IDs do not count twice, vanished events stay', async (t) => {
  const f = fixture(t);
  f.put();
  f.put('msg_2');
  await f.ingest();
  const before = f.ledger.read.totals();
  const rotated = join(f.root, 'rotated.db');
  copyFileSync(f.file, rotated);
  const copy = await f.ingest(rotated);
  assert.equal(copy.inserted, 0);
  assert.deepEqual(f.ledger.read.totals(), before);
  // 单批写入会更新 source_file；回到原库后再验证同一文件截断的告警。
  await f.ingest();
  f.db.exec("DELETE FROM session_message WHERE id = 'msg_2'");
  const truncated = await f.ingest();
  assert.ok(truncated.anomalies.some(text => text.includes('vanished')));
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('kilo bad rows and missing fields: counted separately, unknown remains NULL', async (t) => {
  const f = fixture(t);
  f.put('msg_bad_json', '{');
  f.put('msg_null', 'null');
  f.put('msg_missing', assistant({ tokens: { output: '7', cache: { read: -1, write: 'bad' } } }));
  f.put('msg_bad_time', assistant({ time: { created: 'invalid' } }));
  f.put('msg_zero', assistant({ tokens: { input: 0, output: 0 } }));
  f.put('msg_no_tokens', assistant({ tokens: undefined }));
  const notes = newNotes();
  const records = await f.parse(f.file, notes);
  assert.equal(records.length, 1);
  assert.equal(records[0].input_tokens, null);
  assert.equal(records[0].output_tokens, 7);
  assert.equal(records[0].cache_read_tokens, null);
  assert.equal(records[0].cache_write_tokens, null);
  assert.deepEqual(notes, { bad_lines: 2, bad_fields: 2, bad_times: 1, zero_usage: 1 });
  await f.ingest();
  assert.equal(f.ledger.read.totals().gross_tokens, 7);
  assert.equal(f.ledger.read.totals().record_count, 1);
});

test('kilo synthetic client totals: zero delta without compatibility projections', async (t) => {
  const f = fixture(t);
  f.put();
  f.put('msg_2', assistant({ tokens: { input: 50, output: 8, reasoning: 2, cache: { read: 4, write: 1 } } }));
  // Independent synthetic client totals, not calculated through the adapter.
  f.db.exec("INSERT INTO session VALUES ('ses_1', 150, 28, 7, 34, 11)");
  f.db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?)').run('msg_1', 'ses_1', created, created, JSON.stringify({ role: 'assistant', modelID: 'legacy', tokens: assistant().tokens }));
  f.db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)').run('part_1', 'msg_1', 'ses_1', created, created, JSON.stringify({ type: 'step-finish', tokens: assistant().tokens }));
  await f.ingest();
  const client = f.db.prepare('SELECT * FROM session').get();
  const actual = f.ledger.read.totals();
  assert.equal(actual.record_count, 2);
  assert.deepEqual([
    actual.input_tokens - client.tokens_input,
    actual.output_tokens - client.tokens_output - client.tokens_reasoning,
    actual.cache_read_tokens - client.tokens_cache_read,
    actual.cache_write_tokens - client.tokens_cache_write
  ], [0, 0, 0, 0]);
  assert.equal(actual.gross_tokens, 230);
  f.db.exec('DELETE FROM session_message');
  assert.deepEqual(await f.parse(), [], 'no fallback to duplicate or cumulative representations');
});

test('kilo missing model: stored as NULL and unpriced', async (t) => {
  const f = fixture(t);
  f.put('msg_1', assistant({ model: undefined }));
  assert.equal((await f.parse())[0].model, null);
  await f.ingest();
  assert.equal(f.ledger.read.sourceChecks({ now: '2026-10-26T00:00:00.000Z' }).get('kilo').null_model, 1);
  assert.equal(f.ledger.read.totals().unpriced_records, 1);
});

test('kilo legacy placeholder: never becomes a priced model', async (t) => {
  const f = fixture(t);
  f.put('msg_1', assistant({ model: { id: 'legacy', providerID: 'legacy' } }));
  assert.equal((await f.parse())[0].model, null);
  await f.ingest();
  assert.equal(f.ledger.read.sourceChecks({ now: '2026-10-26T00:00:00.000Z' }).get('kilo').null_model, 1);
});

test('kilo reasoning: add separate reasoning once, retain unknown output as NULL', async (t) => {
  const f = fixture(t);
  f.put('msg_1', assistant({ tokens: { output: 12, reasoning: 8 } }));
  f.put('msg_2', assistant({ tokens: { reasoning: 9 } }));
  f.put('msg_3', assistant({ tokens: { input: 1 } }));
  assert.deepEqual((await f.parse()).map(row => row.output_tokens), [20, 9, null]);
});

test('kilo read-only: source bytes and journal mode stay unchanged', async (t) => {
  const f = fixture(t);
  f.put();
  const before = readFileSync(f.file);
  const mode = f.db.prepare('PRAGMA journal_mode').get();
  await f.parse();
  assert.deepEqual(readFileSync(f.file), before);
  assert.deepEqual(f.db.prepare('PRAGMA journal_mode').get(), mode);
  assert.equal(existsSync(`${f.file}-wal`), false);
  assert.equal(existsSync(`${f.file}-shm`), false);
  const absent = join(f.root, 'absent.db');
  assert.deepEqual(await f.parse(absent), []);
  assert.equal(existsSync(absent), false);
});

test('kilo discovery: XDG defaults and KILO_DB overrides, never KILO_HOME or AppData', (t) => {
  const f = fixture(t);
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_DATA_HOME', 'KILO_DB', 'KILO_HOME'];
  const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  t.after(() => {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  });
  Object.assign(process.env, { HOME: f.root, USERPROFILE: f.root, APPDATA: join(f.root, 'roaming'), LOCALAPPDATA: join(f.root, 'local'), KILO_HOME: join(f.root, 'unsupported') });
  delete process.env.XDG_DATA_HOME;
  delete process.env.KILO_DB;
  assert.equal(homedir(), f.root);
  const make = (base, name = 'kilo.db') => {
    mkdirSync(base, { recursive: true });
    const file = join(base, name);
    copyFileSync(f.file, file);
    return file;
  };
  const expected = make(join(f.root, '.local', 'share', 'kilo'));
  make(join(f.root, 'roaming', 'kilo'));
  make(join(f.root, 'local', 'kilo'));
  make(process.env.KILO_HOME);
  assert.deepEqual(discoverAll().kilo, [expected]);
  const xdg = join(f.root, 'xdg');
  const custom = make(join(xdg, 'kilo'));
  process.env.XDG_DATA_HOME = xdg;
  assert.deepEqual(discoverAll().kilo, [custom]);
  const relative = make(join(xdg, 'kilo'), 'kilo-dev.db');
  process.env.KILO_DB = 'kilo-dev.db';
  assert.deepEqual(discoverAll().kilo, [relative]);
  process.env.KILO_DB = f.file;
  assert.deepEqual(discoverAll().kilo, [f.file]);
  process.env.KILO_DB = ':memory:';
  assert.deepEqual(discoverAll().kilo, []);
  process.env.KILO_DB = 'missing.db';
  assert.deepEqual(discoverAll().kilo, []);
});
