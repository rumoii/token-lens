import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { discoverAll } from '../../src/core/discovery.js';
import { DatabaseSync } from 'node:sqlite';
import { parseZcode } from '../../src/core/adapters/zcode.js';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';

const started = 1792960000000;
const usageId = 'usage_model_turn_msg_1_0';
// ZCode 3c5b22764937: adapters/src/storage/session-store/schema.baseline.sql:101-142.
const usageSchema = `CREATE TABLE model_usage (
  id text primary key,
  logical_request_id text not null,
  attempt_index integer not null default 0,
  session_id text not null references session(id) on delete cascade,
  turn_id text, trace_id text, span_id text, assistant_message_id text, parent_user_message_id text,
  query_source text not null, provider_id text not null, model_id text not null,
  variant text, agent text, mode text, task_type text,
  status text not null check(status in ('running', 'completed', 'error', 'cancelled')),
  started_at integer not null, first_token_at integer, completed_at integer,
  duration_ms integer, time_to_first_token_ms integer, finish_reason text,
  tool_call_count integer not null default 0,
  input_tokens integer not null default 0, output_tokens integer not null default 0,
  reasoning_tokens integer not null default 0,
  cache_creation_input_tokens integer not null default 0,
  cache_read_input_tokens integer not null default 0,
  provider_total_tokens integer, computed_total_tokens integer not null default 0,
  retry_count integer not null default 0,
  retryable integer not null default 0 check(retryable in (0, 1)),
  cancelled_by_user integer not null default 0 check(cancelled_by_user in (0, 1)),
  context_exceeded integer not null default 0 check(context_exceeded in (0, 1)),
  error_type text, error_code text, error_message text, raw_usage_json text, provider_metadata_json text
);`;

function fixture(t, { nullable = false } = {}) {
  let db, ledger;
  t.after(() => { try { ledger?.close(); } finally { db?.close(); } });
  const root = temporary(t);
  const file = join(root, 'db.sqlite');
  db = new DatabaseSync(file);
  ledger = new Ledger(join(root, 'ledger.db'));
  // Orphan/missing-session fixtures intentionally exercise damaged source relationships.
  db.exec('PRAGMA foreign_keys = OFF');
  // Only the session columns queried by the adapter; types follow schema.baseline.sql:162-184.
  db.exec('CREATE TABLE session (id text primary key, directory text not null)');
  // Malformed/older schemas deliberately allow NULL to exercise the unknown-value contract.
  db.exec(nullable ? usageSchema.replaceAll(' not null', '') : usageSchema);
  const put = (id = usageId, fields = {}) => {
    const row = { id, logical_request_id: 'msg_1', session_id: 'ses_1', query_source: 'turn',
      provider_id: 'anthropic', model_id: 'claude-opus-5-5', status: 'completed', started_at: started,
      input_tokens: 1000, output_tokens: 200, reasoning_tokens: 50,
      cache_read_input_tokens: 600, cache_creation_input_tokens: 100,
      provider_total_tokens: 1200, computed_total_tokens: 1200, ...fields };
    const columns = Object.keys(row);
    db.prepare(`INSERT OR REPLACE INTO model_usage (${columns.join(',')}) VALUES (${columns.map(() => '?').join(',')})`)
      .run(...Object.values(row));
  };
  const parse = (path = file, notes) => Array.fromAsync(parseZcode(path, notes));
  const ingest = async (path = file) => ledger.write.ingestBatch(await parse(path), {
    priceOf: costOf, sourceFile: path, parserRev: 1
  });
  return { root, file, db, ledger, put, parse, ingest };
}

function temporary(t) {
  const parent = realpathSync(tmpdir());
  const root = mkdtempSync(join(parent, 'tl-zcode-'));
  t.after(() => {
    assert.equal(dirname(root), parent);
    assert.ok(basename(root).startsWith('tl-zcode-'));
    assert.equal(realpathSync(root), root);
    rmSync(root, { recursive: true, force: true });
  });
  return root;
}

function isolatedHome(t, root) {
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'ZCODE_DATA_BASE_DIR',
    'ZCODE_SESSION_DB_PATH', 'ZCODE_SESSION_DB'];
  const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  t.after(() => {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  });
  for (const key of keys) delete process.env[key];
  Object.assign(process.env, { HOME: root, USERPROFILE: root,
    APPDATA: join(root, 'roaming'), LOCALAPPDATA: join(root, 'local') });
  assert.equal(homedir(), root);
}

test('zcode discovery: default database only when present, after codebuddy', (t) => {
  const root = temporary(t);
  isolatedHome(t, root);
  assert.deepEqual(discoverAll().zcode, []);
  const directory = join(root, '.zcode', 'cli', 'db');
  mkdirSync(directory, { recursive: true });
  const file = join(directory, 'db.sqlite');
  writeFileSync(file, '');
  const found = discoverAll();
  assert.deepEqual(found.zcode, [file]);
  assert.equal(Object.keys(found).indexOf('zcode'), Object.keys(found).indexOf('codebuddy') + 1);
});

test('zcode normal: disjoint cache fields, inclusive output and UTC request start', async (t) => {
  assert.equal(adapters.zcode, parseZcode);
  assert.equal(PARSER_REV.zcode, 1);
  const f = fixture(t);
  f.put();
  assert.deepEqual(await f.parse(), [{
    record_key: `zcode|ses_1|${usageId}`, source: 'zcode', session_id: 'ses_1', project_key: null,
    model: 'claude-opus-5-5', provider: 'anthropic', observed_at: '2026-10-25T20:26:40.000Z', kind: 'event',
    input_tokens: 300, output_tokens: 200, cache_read_tokens: 600, cache_write_tokens: 100,
    cache_creation_tokens: 100
  }]);
});

test('zcode repeat collection: row count, tokens and cost do not change', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  const before = f.ledger.read.totals();
  assert.equal(before.gross_tokens, 1200);
  assert.ok(before.cost_micros > 0);
  const again = await f.ingest();
  assert.equal(again.unchanged, 1);
  assert.equal(again.inserted, 0);
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('zcode growth: update the stable event and append a separate attempt', async (t) => {
  const f = fixture(t);
  f.put(usageId, { status: 'running' });
  await f.ingest();
  f.put(usageId, { input_tokens: 2000, output_tokens: 300, status: 'completed' });
  const growth = await f.ingest();
  assert.equal(growth.updated, 1);
  assert.equal(growth.inserted, 0);
  assert.equal(f.ledger.read.totals().record_count, 1);
  assert.equal(f.ledger.read.totals().input_tokens, 1300);
  f.put('usage_model_turn_msg_1_1', { attempt_index: 1 });
  assert.equal((await f.ingest()).inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
});

// Contract case 4 is N/A: model_usage stores request events, never cumulative session snapshots.
test('zcode correction: a smaller event overwrites instead of accumulating', async (t) => {
  const f = fixture(t);
  f.put();
  await f.ingest();
  f.put(usageId, { input_tokens: 800, output_tokens: 100 });
  assert.equal((await f.ingest()).updated, 1);
  assert.equal(f.ledger.read.totals().gross_tokens, 900);
  assert.equal(f.ledger.read.totals().record_count, 1);
});

test('zcode rotation and pruning: copied IDs deduplicate; vanished rows remain active', async (t) => {
  const f = fixture(t);
  f.put();
  f.put('usage_model_turn_msg_2_0');
  await f.ingest();
  const before = f.ledger.read.totals();
  const rotated = join(f.root, 'rotated.sqlite');
  copyFileSync(f.file, rotated);
  assert.equal((await f.ingest(rotated)).inserted, 0);
  assert.deepEqual(f.ledger.read.totals(), before);
  await f.ingest();
  f.db.prepare('DELETE FROM model_usage WHERE id = ?').run(usageId);
  const pruned = await f.ingest();
  assert.equal(pruned.counts.vanished, 1);
  assert.equal(pruned.counts.deactivated, 0);
  assert.match(pruned.anomalies.join('\n'), /vanished/);
  assert.deepEqual(f.ledger.read.totals(), before);
  const db = new DatabaseSync(join(f.root, 'ledger.db'), { readOnly: true });
  try {
    assert.equal(db.prepare('SELECT active FROM usage_records WHERE record_key = ?')
      .get(`zcode|ses_1|${usageId}`).active, 1);
  } finally { db.close(); }
});

test('zcode bad fields and times: count diagnostics without poisoning valid usage', async (t) => {
  const f = fixture(t, { nullable: true });
  f.put('bad-time', { started_at: 'invalid' });
  f.put('no-time', { started_at: null });
  f.put('bad-fields', { input_tokens: -1, output_tokens: '7', cache_read_input_tokens: 'bad', cache_creation_input_tokens: 1.5 });
  f.put(null);
  f.put('');
  const notes = newNotes();
  const rows = await f.parse(f.file, notes);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].input_tokens, null);
  assert.equal(rows[0].output_tokens, 7);
  assert.equal(rows[0].cache_read_tokens, null);
  assert.equal(rows[0].cache_write_tokens, null);
  assert.equal(notes.bad_fields, 3);
  assert.equal(notes.bad_lines, 2);
  assert.equal(notes.bad_times, 2);
  assert.equal(Object.hasOwn(notes, 'bad_time'), false);
  await f.ingest();
  assert.equal(f.ledger.read.totals().gross_tokens, 7);
});

test('zcode NULL fields: keep unknowns and subtract only known cache components', async (t) => {
  const f = fixture(t, { nullable: true });
  f.put('a', { input_tokens: null, output_tokens: null });
  f.put('b', { cache_read_input_tokens: null, cache_creation_input_tokens: null });
  f.put('c', { cache_read_input_tokens: null });
  f.put('d', { cache_creation_input_tokens: null });
  assert.deepEqual((await f.parse()).map(row => [row.input_tokens, row.output_tokens, row.cache_read_tokens, row.cache_write_tokens]), [
    [null, null, 600, 100], [1000, 200, null, null], [900, 200, null, 100], [400, 200, 600, null]
  ]);
});

test('zcode negative input: record NULL and bad_fields without clamping', async (t) => {
  const f = fixture(t);
  f.put(usageId, { input_tokens: 500 });
  const notes = newNotes();
  const [row] = await f.parse(f.file, notes);
  assert.equal(row.input_tokens, null);
  assert.equal(row.cache_read_tokens, 600);
  assert.equal(row.cache_write_tokens, 100);
  assert.equal(notes.bad_fields, 1);
  assert.equal(Object.hasOwn(notes, 'negative_input'), false);
});

test('zcode zero usage: skip all-zero/all-NULL rows and never add reasoning or totals', async (t) => {
  const f = fixture(t, { nullable: true });
  for (const [id, value] of [['zero', 0], ['unknown', null]]) {
    f.put(id, { input_tokens: value, output_tokens: value,
      cache_read_input_tokens: value, cache_creation_input_tokens: value,
      reasoning_tokens: 50, provider_total_tokens: 5000, computed_total_tokens: 5000 });
  }
  const notes = newNotes();
  assert.deepEqual(await f.parse(f.file, notes), []);
  assert.equal(notes.zero_usage, 2);
});

test('zcode status: account for every status when nonzero usage exists', async (t) => {
  const f = fixture(t);
  for (const status of ['running', 'completed', 'error', 'cancelled']) f.put(status, { status });
  assert.equal((await f.parse()).length, 4);
  await f.ingest();
  assert.equal(f.ledger.read.totals().gross_tokens, 4800);
});

test('zcode missing identity metadata: NULL model/provider/session, stable dash fallback', async (t) => {
  const f = fixture(t, { nullable: true });
  f.put('a', { session_id: null, model_id: null, provider_id: null });
  f.put('b', { session_id: '', model_id: '  ', provider_id: '' });
  const rows = await f.parse();
  assert.deepEqual(rows.map(row => [row.record_key, row.session_id, row.model, row.provider, row.project_key]), [
    ['zcode|-|a', null, null, null, null], ['zcode|-|b', null, null, null, null]
  ]);
  await f.ingest();
  assert.equal(f.ledger.read.totals().unpriced_records, 2);
});

test('zcode projects: use only the matching session directory', async (t) => {
  const f = fixture(t);
  for (const [id, directory] of [['a', 'D:/work/one/'], ['b', '/srv/two/'], ['c', '  ']]) {
    f.db.prepare('INSERT INTO session VALUES (?, ?)').run(id, directory);
    f.put(id, { session_id: id });
  }
  f.put('orphan', { session_id: 'absent' });
  assert.deepEqual((await f.parse()).map(row => row.project_key), ['D:\\work\\one', '/srv/two', null, null]);
  f.db.exec('DROP TABLE session');
  assert.ok((await f.parse()).every(row => row.project_key === null));
  f.db.exec('CREATE TABLE session (id text primary key)');
  assert.ok((await f.parse()).every(row => row.project_key === null));
});

test('zcode synthetic client totals: four disjoint fields equal provider/computed totals', async (t) => {
  const f = fixture(t);
  f.put();
  f.put('second', { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 30,
    cache_creation_input_tokens: 10, provider_total_tokens: 120, computed_total_tokens: 120 });
  await f.ingest();
  const client = f.db.prepare('SELECT sum(provider_total_tokens) p, sum(computed_total_tokens) c FROM model_usage').get();
  const totals = f.ledger.read.totals();
  assert.deepEqual([totals.input_tokens, totals.output_tokens, totals.cache_read_tokens, totals.cache_write_tokens], [360, 220, 630, 110]);
  assert.equal(totals.gross_tokens, 1320);
  assert.equal(totals.gross_tokens - client.p, 0);
  assert.equal(totals.gross_tokens - client.c, 0);
});

test('zcode read-only: preserve source bytes and journal mode; missing table/file is empty', async (t) => {
  const f = fixture(t);
  f.put();
  const before = readFileSync(f.file);
  const mode = f.db.prepare('PRAGMA journal_mode').get();
  const iterator = parseZcode(f.file);
  assert.equal((await iterator.next()).done, false);
  await iterator.return();
  assert.deepEqual(await f.parse(), await f.parse());
  assert.deepEqual(readFileSync(f.file), before);
  assert.deepEqual(f.db.prepare('PRAGMA journal_mode').get(), mode);
  assert.equal(existsSync(`${f.file}-wal`), false);
  assert.equal(existsSync(`${f.file}-shm`), false);
  const absent = join(f.root, 'absent.sqlite');
  assert.deepEqual(await f.parse(absent), []);
  assert.equal(existsSync(absent), false);
  f.db.exec('DROP TABLE model_usage');
  assert.deepEqual(await f.parse(), []);
});

test('zcode discovery: data-base env and desktop setting retain default history and deduplicate', (t) => {
  const root = temporary(t);
  isolatedHome(t, root);
  const make = base => {
    const dir = join(base, '.zcode', 'cli', 'db');
    mkdirSync(dir, { recursive: true });
    const file = join(dir, 'db.sqlite');
    writeFileSync(file, '');
    return file;
  };
  const original = make(root);
  const envRoot = join(root, 'env');
  const envFile = make(envRoot);
  const settingRoot = join(root, 'desktop');
  const settingFile = make(settingRoot);
  const settings = join(root, '.zcode', 'v2', 'setting.json');
  mkdirSync(dirname(settings), { recursive: true });
  writeFileSync(settings, JSON.stringify({ dataBaseDir: settingRoot }));
  process.env.ZCODE_DATA_BASE_DIR = ` ${envRoot} `;
  assert.deepEqual(discoverAll().zcode, [original, envFile, settingFile]);
  process.env.ZCODE_DATA_BASE_DIR = root;
  writeFileSync(settings, JSON.stringify({ dataBaseDir: root }));
  assert.deepEqual(discoverAll().zcode, [original]);
  writeFileSync(settings, '{');
  assert.deepEqual(discoverAll().zcode, [original]);
  process.env.ZCODE_DATA_BASE_DIR = 'relative-root';
  writeFileSync(settings, JSON.stringify({ dataBaseDir: 'relative-root' }));
  assert.deepEqual(discoverAll().zcode, [original]);
});

test('zcode discovery: explicit DB env aliases/config paths, never resolve against Lens cwd', (t) => {
  const root = temporary(t);
  isolatedHome(t, root);
  const cli = join(root, '.zcode', 'cli');
  mkdirSync(join(cli, 'db'), { recursive: true });
  const original = join(cli, 'db', 'db.sqlite');
  const custom = join(root, 'custom.sqlite');
  writeFileSync(original, '');
  writeFileSync(custom, '');
  writeFileSync(join(cli, 'config.json'), JSON.stringify({ storage: { sessionDbPath: custom } }));
  assert.deepEqual(discoverAll().zcode, [original, custom]);
  writeFileSync(join(cli, 'config.json'), JSON.stringify({ storage: { sessionDbPath: '~/custom.sqlite' } }));
  assert.deepEqual(discoverAll().zcode, [original, custom]);
  writeFileSync(join(cli, 'config.json'), '{');
  process.env.ZCODE_SESSION_DB_PATH = custom;
  assert.deepEqual(discoverAll().zcode, [original, custom]);
  delete process.env.ZCODE_SESSION_DB_PATH;
  process.env.ZCODE_SESSION_DB = '~/custom.sqlite';
  assert.deepEqual(discoverAll().zcode, [original, custom]);
  process.env.ZCODE_SESSION_DB = 'relative.sqlite';
  writeFileSync(join(cli, 'config.json'), JSON.stringify({ storage: { sessionDbPath: 'relative.sqlite' } }));
  assert.deepEqual(discoverAll().zcode, [original]);
});
