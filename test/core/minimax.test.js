import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { discoverAll } from '../../src/core/discovery.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';
import { costOf } from '../../src/core/pricing/engine.js';

const created = 1792960000000;
const usage = (fields = {}) => ({
  session_id: 'ses_1', agent_name: 'main', framework_type: 'pi-agent', turn_id: 'turn_1',
  model: 'MiniMax-M3', ts: created, input_tokens: 100, output_tokens: 20,
  reasoning_tokens: 5, cache_read_tokens: 30, cache_write_tokens: 10,
  cost_usd: null, raw: null, ...fields
});

function fixture(t, { strict = true, sessions = true, workspace = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'tl-minimax-'));
  const file = join(root, 'v2', 'sqlite', 'runtime-state.sqlite');
  mkdirSync(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  const ledger = new Ledger(':memory:');
  t.after(() => {
    try { ledger.close(); } finally {
      try { db.close(); } finally { rmSync(root, { recursive: true, force: true }); }
    }
  });
  const required = strict ? ' NOT NULL' : '';
  db.exec(`
    CREATE TABLE local_runtime_token_usage (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT${required},
      agent_name TEXT${required},
      framework_type TEXT${required},
      turn_id TEXT,
      model TEXT,
      ts INTEGER${required},
      input_tokens INTEGER${required},
      output_tokens INTEGER${required},
      reasoning_tokens INTEGER${required},
      cache_read_tokens INTEGER${required},
      cache_write_tokens INTEGER${required},
      cost_usd REAL,
      raw TEXT
    );
    CREATE INDEX idx_local_runtime_token_usage_session_ts
      ON local_runtime_token_usage(session_id, ts, id);
  `);
  if (sessions) {
    db.exec(`CREATE TABLE local_runtime_sessions (session_id TEXT PRIMARY KEY${workspace ? ', workspace_dir TEXT' : ''})`);
  }
  const put = (id = 1, fields = {}) => {
    const row = usage(fields);
    db.prepare(`
      INSERT OR REPLACE INTO local_runtime_token_usage (
        id, session_id, agent_name, framework_type, turn_id, model, ts,
        input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_write_tokens, cost_usd, raw
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id, row.session_id, row.agent_name, row.framework_type, row.turn_id, row.model, row.ts,
      row.input_tokens, row.output_tokens, row.reasoning_tokens,
      row.cache_read_tokens, row.cache_write_tokens, row.cost_usd, row.raw
    );
  };
  const parse = async (path = file, notes) => {
    assert.equal(typeof adapters.minimax, 'function', 'minimax parser must be registered');
    return Array.fromAsync(adapters.minimax(path, notes));
  };
  const ingest = async (path = file, notes) => ledger.write.ingestBatch(await parse(path, notes), {
    priceOf: costOf, sourceFile: path, parserRev: PARSER_REV.minimax
  });
  return { root, file, db, ledger, put, parse, ingest };
}

test('minimax normal: millisecond time, stable IDs, exclusive tokens and session project', async (t) => {
  assert.equal(PARSER_REV.minimax, 4);
  const f = fixture(t);
  f.put();
  f.db.prepare('INSERT INTO local_runtime_sessions VALUES (?, ?)').run('ses_1', 'D:/work/one/');
  const [row] = await f.parse();
  assert.deepEqual(row, {
    record_key: 'minimax|ses_1|1', source: 'minimax', session_id: 'ses_1', project_key: 'D:\\work\\one',
    model: 'MiniMax-M3', provider: null, observed_at: '2026-10-25T20:26:40.000Z', kind: 'event',
    input_tokens: 100, output_tokens: 20, cache_read_tokens: 30, cache_write_tokens: 10,
    cache_creation_tokens: 10
  });
  assert.equal('timestamp' in row, false);
});

test('minimax output already includes reasoning: never add reasoning tokens again', async (t) => {
  const f = fixture(t);
  f.put(1, { output_tokens: 300, reasoning_tokens: 120 });
  const [row] = await f.parse();
  assert.equal(row.output_tokens, 300);
});

test('minimax repeat collection: row count, tokens and cost stay unchanged', async (t) => {
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

test('minimax growth: update the same event and append only a new row', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  f.put(1, { input_tokens: 200, output_tokens: 40, reasoning_tokens: 10 });
  const growth = await f.ingest();
  assert.equal(growth.updated, 1);
  assert.equal(growth.inserted, 0);
  assert.equal(f.ledger.read.totals().record_count, 1);
  assert.equal(f.ledger.read.totals().input_tokens, 200);
  assert.equal(f.ledger.read.totals().output_tokens, 40);
  f.put(2);
  const append = await f.ingest();
  assert.equal(append.inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
});

// 每条 local_runtime_token_usage 都是逐请求事件；客户端没有会话级累计快照，累计覆盖用例不适用。
test('minimax snapshot semantics: changed event values overwrite without cumulative addition', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  f.put(1, { input_tokens: 70, output_tokens: 10, reasoning_tokens: 2, cache_read_tokens: 8, cache_write_tokens: 3 });
  const changed = await f.ingest();
  assert.equal(changed.updated, 1);
  const total = f.ledger.read.totals();
  assert.equal(total.record_count, 1);
  assert.equal(total.gross_tokens, 91);
  assert.ok((await f.parse()).every(row => row.kind === 'event'));
});

test('minimax rotation and truncation: copied IDs do not count twice, vanished events stay', async (t) => {
  const f = fixture(t);
  f.put();
  f.put(2);
  await f.ingest();
  const before = f.ledger.read.totals();
  const rotated = join(f.root, 'rotated.sqlite');
  copyFileSync(f.file, rotated);
  const copy = await f.ingest(rotated);
  assert.equal(copy.inserted, 0);
  assert.deepEqual(f.ledger.read.totals(), before);
  await f.ingest();
  f.db.exec('DELETE FROM local_runtime_token_usage WHERE id = 2');
  const truncated = await f.ingest();
  assert.ok(truncated.anomalies.some(text => text.includes('vanished')));
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('minimax rewind deletion: vanished row stays active with unchanged totals', async (t) => {
  const f = fixture(t);
  f.put();
  f.put(2, { turn_id: 'turn_2' });
  const ledgerDb = openLedger(':memory:');
  t.after(() => ledgerDb.close());
  const writer = new LedgerWriter(ledgerDb);
  const options = { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.minimax };
  writer.ingestBatch(await f.parse(), options);
  const before = ledgerDb.prepare('SELECT record_key, active, input_tokens, output_tokens FROM usage_records ORDER BY record_key').all();
  f.db.exec("DELETE FROM local_runtime_token_usage WHERE turn_id = 'turn_2'");
  const result = writer.ingestBatch(await f.parse(), options);
  assert.equal(result.counts.vanished, 1);
  assert.equal(result.counts.deactivated, 0);
  assert.deepEqual(ledgerDb.prepare('SELECT record_key, active, input_tokens, output_tokens FROM usage_records ORDER BY record_key').all(), before);
  assert.ok(before.every(row => row.active === 1));
});

test('minimax bad rows and missing fields: counted separately, unknown remains NULL', async (t) => {
  const f = fixture(t, { strict: false });
  f.put(1, { input_tokens: null, output_tokens: '7', reasoning_tokens: null, cache_read_tokens: -1, cache_write_tokens: 'bad' });
  f.put(2, { session_id: null });
  f.put(3, { ts: 'invalid' });
  const notes = newNotes();
  const records = await f.parse(f.file, notes);
  assert.equal(records.length, 1);
  assert.equal(records[0].input_tokens, null);
  assert.equal(records[0].output_tokens, 7);
  assert.equal(records[0].cache_read_tokens, null);
  assert.equal(records[0].cache_write_tokens, null);
  assert.equal(records[0].cache_creation_tokens, null);
  assert.deepEqual(notes, { bad_lines: 1, bad_fields: 2, bad_times: 1, zero_usage: 0 });
  await f.ingest();
  assert.equal(f.ledger.read.totals().gross_tokens, 7);
  assert.equal(f.ledger.read.totals().record_count, 1);
});

test('minimax zero usage: all-zero and unknown rows are skipped and counted', async (t) => {
  const f = fixture(t, { strict: false });
  f.put(1, { input_tokens: 0, output_tokens: 0, reasoning_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 });
  f.put(2, { input_tokens: null, output_tokens: null, reasoning_tokens: null, cache_read_tokens: null, cache_write_tokens: null });
  const notes = newNotes();
  assert.deepEqual(await f.parse(f.file, notes), []);
  assert.deepEqual(notes, { bad_lines: 0, bad_fields: 0, bad_times: 0, zero_usage: 2 });
});

test('minimax client summary: four token totals match source columns without reasoning double count', async (t) => {
  const f = fixture(t);
  f.put();
  f.put(2, { input_tokens: 50, output_tokens: 8, reasoning_tokens: 2, cache_read_tokens: 4, cache_write_tokens: 1 });
  await f.ingest();
  const client = f.db.prepare(`
    SELECT sum(input_tokens) input, sum(output_tokens) output,
      sum(cache_read_tokens) cache_read, sum(cache_write_tokens) cache_write
    FROM local_runtime_token_usage WHERE session_id = 'ses_1'
  `).get();
  const actual = f.ledger.read.totals();
  assert.equal(actual.record_count, 2);
  assert.deepEqual([
    actual.input_tokens - client.input,
    actual.output_tokens - client.output,
    actual.cache_read_tokens - client.cache_read,
    actual.cache_write_tokens - client.cache_write
  ], [0, 0, 0, 0]);
  assert.equal(actual.gross_tokens, 223);
});

test('minimax projects: missing session metadata and blank model remain NULL', async (t) => {
  const noSessions = fixture(t, { sessions: false });
  noSessions.put(1, { model: '  ' });
  const [withoutTable] = await noSessions.parse();
  assert.equal(withoutTable.project_key, null);
  assert.equal(withoutTable.model, null);
  const noWorkspace = fixture(t, { workspace: false });
  noWorkspace.put();
  noWorkspace.db.prepare('INSERT INTO local_runtime_sessions VALUES (?)').run('ses_1');
  assert.equal((await noWorkspace.parse())[0].project_key, null);
  const orphan = fixture(t);
  orphan.put();
  assert.equal((await orphan.parse())[0].project_key, null);
});

test('minimax table absence and read-only access: no output and no source changes', async (t) => {
  const f = fixture(t);
  f.put();
  const before = readFileSync(f.file);
  const mode = f.db.prepare('PRAGMA journal_mode').get();
  await f.parse();
  assert.deepEqual(readFileSync(f.file), before);
  assert.deepEqual(f.db.prepare('PRAGMA journal_mode').get(), mode);
  assert.equal(existsSync(`${f.file}-wal`), false);
  assert.equal(existsSync(`${f.file}-shm`), false);
  const absent = join(f.root, 'absent.sqlite');
  assert.deepEqual(await f.parse(absent), []);
  assert.equal(existsSync(absent), false);
  f.db.exec('DROP TABLE local_runtime_token_usage');
  assert.deepEqual(await f.parse(), []);
});

test('minimax discovery: default, profile, legacy and MINIMAX_DATA_DIR override only', (t) => {
  const f = fixture(t);
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'MINIMAX_DATA_DIR', 'MAVIS_DATA_DIR', 'MINIMAX_HOME'];
  const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  t.after(() => {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  });
  const home = join(f.root, 'home');
  mkdirSync(home, { recursive: true });
  Object.assign(process.env, { HOME: home, USERPROFILE: home, APPDATA: join(home, 'roaming'), LOCALAPPDATA: join(home, 'local') });
  for (const key of keys.slice(4)) delete process.env[key];
  assert.equal(homedir(), home);
  const make = base => {
    const file = join(base, 'v2', 'sqlite', 'runtime-state.sqlite');
    mkdirSync(dirname(file), { recursive: true });
    copyFileSync(f.file, file);
    return file;
  };
  const expected = [make(join(home, '.minimax')), make(join(home, '.minimax-work')), make(join(home, '.minimax-code'))];
  const oldJson = join(home, '.minimax', 'sessions', 'old.jsonl');
  mkdirSync(dirname(oldJson), { recursive: true });
  writeFileSync(oldJson, '{"usage":{"input_tokens":900}}\n');
  make(join(home, 'roaming', 'minimax'));
  make(join(home, '.config', 'minimax'));
  make(process.env.MINIMAX_HOME || join(home, 'unsupported'));
  assert.deepEqual(discoverAll().minimax.sort(), expected.sort());
  const override = make(join(f.root, 'override'));
  process.env.MINIMAX_DATA_DIR = join(f.root, 'override');
  assert.deepEqual(discoverAll().minimax, [override]);
  process.env.MINIMAX_DATA_DIR = join(f.root, 'missing');
  assert.deepEqual(discoverAll().minimax, []);
});
