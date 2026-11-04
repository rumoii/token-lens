import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { zstdCompressSync } from 'node:zlib';
import { adapters } from '../../src/core/adapters/index.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { runIngestion } from '../../src/core/ingest.js';

const ts = '2026-10-20T01:00:00.000Z';
const collect = async (source, file) => Array.fromAsync(adapters[source](file));
function text(file, value) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
  return file;
}
function database(file, schema, rows) {
  mkdirSync(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  try {
    db.exec(schema);
    for (const [sql, values] of rows) db.prepare(sql).run(...values);
  } finally { db.close(); }
  return file;
}
async function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), 'tl-l5-'));
  try { await fn(root); }
  finally { rmSync(root, { recursive: true, force: true }); }
}
// Seed keys independently of the parser, then exercise the real replaces consumer.
function migrated(records, oldKeys) {
  const ledger = new Ledger(':memory:');
  try {
    for (const key of new Set(oldKeys)) {
      const record = records[0];
      ledger.write.ingestBatch([{ ...record, record_key: key, replaces: undefined }]);
    }
    assert.equal(new Set(records.map(r => r.record_key)).size, records.length);
    for (const key of oldKeys) assert.ok(records.some(r => r.replaces?.includes(key)), key);
    const result = ledger.write.ingestBatch(records);
    assert.equal(result.counts.replaced, new Set(oldKeys).size);
    const totals = ledger.read.totals();
    assert.equal(totals.record_count, records.length);
    assert.equal(totals.gross_tokens, records.reduce((n, r) => n + ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'].reduce((s, f) => s + (r[f] ?? 0), 0), 0));
    assert.equal(ledger.write.ingestBatch(records).unchanged, records.length);
    assert.deepEqual(ledger.read.totals(), totals);
  } finally { ledger.close(); }
}

test('L5 aider: OpenAI prompt subtracts cache regardless of cache field spelling', async () => fixture(async root => {
  const rows = ['cache_read_input_tokens', 'cache_read'].map(key => ({
    session_id: 's', timestamp: ts, usage: { prompt_tokens: 100, completion_tokens: 5, [key]: 40 }
  }));
  rows.push({ session_id: 's', timestamp: ts, usage: { input_tokens: 100, output_tokens: 5, cache_read_input_tokens: 40, cache_creation_input_tokens: 20 } });
  const records = await collect('aider', text(join(root, 'history'), rows.map(JSON.stringify).join('\n')));
  assert.deepEqual(records.map(r => r.input_tokens), [60, 60, 100]);
}));

test('L5 aider: calls sharing commit_hash remain distinct and replace the old key', async () => fixture(async root => {
  const row = { session_id: 's', commit_hash: 'commit-a', timestamp: ts, usage: { prompt_tokens: 10, completion_tokens: 5 } };
  const file = text(join(root, 'history'), [row, row].map(JSON.stringify).join('\n'));
  const records = await collect('aider', file);
  migrated(records, ['aider|s|commit-a']);
  text(file, [{ ...row, usage: { prompt_tokens: 20, completion_tokens: 5 } }, row].map(JSON.stringify).join('\n'));
  assert.deepEqual((await collect('aider', file)).map(r => r.record_key), records.map(r => r.record_key));
}));

for (const shape of ['composer', 'chat']) test(`L5 cursor: ${shape} without IDs keeps every item and file; migrates constants`, async () => fixture(async root => {
  const key = shape === 'composer' ? 'composerData' : 'workbench.panel.aichat.view.aichat.chatdata';
  const item = { createdAt: ts, messages: [{ role: 'user', tokenCount: 10 }, { role: 'assistant', tokenCount: 5 }] };
  const payload = shape === 'composer' ? [item, item] : { tabs: [item, item] };
  const records = [];
  for (const name of ['a', 'b']) {
    const file = database(join(root, name, 'state.vscdb'), 'CREATE TABLE ItemTable(key TEXT, value TEXT)', [
      ['INSERT INTO ItemTable VALUES (?,?)', [key, JSON.stringify(payload)]]
    ]);
    records.push(...await collect('cursor', file));
  }
  migrated(records, [`cursor|${shape === 'composer' ? 'composer-session' : 'chat-session'}`]);
}));

test('L5 cursor: equal CSV basenames in different directories cannot overwrite', async () => fixture(async root => {
  const csv = `Date,Model,Input Tokens,Output Tokens\n${ts},gpt-4o,10,5\n`;
  const records = [];
  for (const name of ['a', 'b']) records.push(...await collect('cursor', text(join(root, name, 'cursor.csv'), csv)));
  migrated(records, [`cursor|cursor|${ts}|1`]);
}));

test('L5 cursor: missing model stays NULL in CSV, composer and chat', async () => fixture(async root => {
  const records = await collect('cursor', text(join(root, 'cursor.csv'), `Date,Model,Input Tokens,Output Tokens\n${ts},,10,5\n`));
  const item = { createdAt: ts, messages: [{ tokenCount: 5, model: 'message-only-model' }] };
  const file = database(join(root, 'state.vscdb'), 'CREATE TABLE ItemTable(key TEXT, value TEXT)', [
    ['INSERT INTO ItemTable VALUES (?,?)', ['composerData', JSON.stringify([item])]],
    ['INSERT INTO ItemTable VALUES (?,?)', ['workbench.panel.aichat.view.aichat.chatdata', JSON.stringify({ tabs: [item] })]]
  ]);
  records.push(...await collect('cursor', file));
  assert.deepEqual(records.map(r => r.model), [null, null, null]);
}));

test('L5 trae: same session snapshots keep separate identities and cumulative semantics', async () => fixture(async root => {
  const file = text(join(root, 'trae.json'), { sessions: [10, 20].map(input => ({
    session_id: 's', timestamp: ts, input_token: input, output_token: 5
  })) });
  const records = await collect('trae', file);
  assert.deepEqual(records.map(r => r.kind), ['cumulative', 'cumulative']);
  migrated(records, ['trae|s']);
}));

test('L5 codex: turn_id is not a response ID; fallback is file and physical line', async () => fixture(async root => {
  const row = { type: 'token_usage_record', timestamp: ts, payload: { session_id: 's', turn_id: 't', usage: { input_tokens: 10, output_tokens: 5 } } };
  const records = [];
  for (const name of ['a', 'b']) records.push(...await collect('codex', text(join(root, name + '.jsonl'), [row, row].map(JSON.stringify).join('\n'))));
  migrated(records, ['codex|s|t']);
  assert.ok(records.every(r => /\|f[0-9a-f]{12}:[12]$/.test(r.record_key)));
}));

test('L5 codex: compressing a rollout preserves positional keys and active token totals', async () => fixture(async root => {
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA'];
  const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  const home = join(root, 'home');
  const data = join(root, 'data');
  const plain = join(home, '.codex', 'sessions', '2026', '10', 'rollout-compression.jsonl');
  const compressed = plain + '.zst';
  const content = [
    JSON.stringify({ type: 'session_meta', payload: { session_id: 'compression-session' } }),
    '',
    ...[[100, 40, 5], [20, 0, 3]].map(([input, cached, output]) => JSON.stringify({
      type: 'token_usage_record', timestamp: ts,
      payload: { turn_id: 'shared-turn', usage: { input_tokens: input, cached_input_tokens: cached, output_tokens: output } }
    }))
  ].join('\n') + '\n';
  text(plain, content);
  Object.assign(process.env, { HOME: home, USERPROFILE: home, APPDATA: join(home, 'roaming'), LOCALAPPDATA: join(home, 'local') });
  const snapshot = () => {
    const ledger = new Ledger(join(data, 'ledger.db'));
    let totals;
    try { totals = ledger.read.totals(); }
    finally { ledger.close(); }
    const db = new DatabaseSync(join(data, 'ledger.db'), { readOnly: true });
    try {
      const records = db.prepare('SELECT record_key, source_file FROM usage_records WHERE active = 1 ORDER BY record_key').all();
      return { totals, records };
    } finally { db.close(); }
  };
  try {
    const first = await runIngestion({ dataDir: data });
    assert.deepEqual(first.anomalies, []);
    const before = snapshot();
    assert.equal(before.totals.record_count, 2);
    assert.deepEqual(['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens', 'gross_tokens'].map(field => before.totals[field]), [80, 8, 40, null, 128]);
    assert.ok(before.records.every(record => record.source_file === plain));

    // 原文件不再存在，真实采集只能发现同内容的 zstd 文件。
    renameSync(plain, compressed);
    writeFileSync(compressed, zstdCompressSync(Buffer.from(content)));
    const second = await runIngestion({ dataDir: data });
    const after = snapshot();
    assert.equal(after.totals.record_count, 2, '压缩替换不能留下两套活跃位置键');
    assert.deepEqual(after.totals, before.totals, '四类 token 与 gross 均保持不变');
    assert.deepEqual(after.records.map(record => record.record_key), before.records.map(record => record.record_key));
    assert.ok(after.records.every(record => record.source_file === compressed));
    assert.equal(second.inserted + second.updated, 0);
    assert.equal(second.unchanged, 2);
    assert.deepEqual(second.anomalies, []);
  } finally {
    for (const key of keys) { if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key]; }
  }
}));

test('L5 opencode: fallback distinguishes rows with equal timestamps and no IDs', async () => fixture(async root => {
  const records = [];
  for (const name of ['a', 'b']) {
    const file = database(join(root, name, 'opencode.db'), 'CREATE TABLE message(id TEXT, session_id TEXT, time_updated TEXT, time_created TEXT, data TEXT)',
      [10, 20].map(input => ['INSERT INTO message VALUES (?,?,?,?,?)', [null, 's', ts, ts, JSON.stringify({ tokens: { input, output: 5 } })]]));
    records.push(...await collect('opencode', file));
  }
  migrated(records, [`opencode|s|${ts}`]);
}));

test('L5 goose: unexplained total remainder never becomes output or known cache', async () => fixture(async root => {
  const file = database(join(root, 'sessions.db'), 'CREATE TABLE sessions(id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER)',
    [[ 'INSERT INTO sessions VALUES (?,?,?,?,?,?,?)', ['s', '{}', 'p', ts, 100, 20, 200] ],
      [ 'INSERT INTO sessions VALUES (?,?,?,?,?,?,?)', ['missing-output', '{}', 'p', ts, 100, null, 200] ],
      [ 'INSERT INTO sessions VALUES (?,?,?,?,?,?,?)', ['total-only', '{}', 'p', ts, null, null, 200] ]]);
  const records = await collect('goose', file);
  assert.deepEqual(records.map(r => [r.output_tokens, r.cache_read_tokens, r.cache_write_tokens]), [[20, null, null], [null, null, null]]);
}));

test('L5 openclaw: archive copies with shifted ordinals share content identity and migrate both keys', async () => fixture(async root => {
  const row = text => ({ session_id: 's', timestamp: ts, message: { role: 'assistant', model: 'm', content: text, usage: { input: 10, output: 5 } } });
  const active = await collect('openclaw', text(join(root, 'active.jsonl'), [row('first'), row('shared')].map(JSON.stringify).join('\n')));
  const archiveFile = text(join(root, 'archive.jsonl'), JSON.stringify(row('shared')));
  const [copy] = await collect('openclaw', archiveFile);
  assert.equal(active[1].record_key, copy.record_key);
  assert.notEqual(active[0].record_key, copy.record_key);
  migrated([{ ...active[1], replaces: [...new Set([...(active[1].replaces || []), ...(copy.replaces || [])])] }], [`openclaw|s|${ts}|1`, `openclaw|s|${ts}|2`]);
  const grown = row('shared'); grown.message.usage.output = 25;
  text(archiveFile, JSON.stringify(grown));
  assert.equal((await collect('openclaw', archiveFile))[0].record_key, copy.record_key, 'tokens never enter identity');
}));

test('L5 openclaw: equal time and text with different raw message IDs remain distinct', async () => fixture(async root => {
  const rows = ['a', 'b'].map(id => ({ id, session_id: 's', timestamp: ts,
    message: { role: 'assistant', content: 'same text', usage: { input: 10, output: 5 } } }));
  const records = await collect('openclaw', text(join(root, 'same.jsonl'), rows.map(JSON.stringify).join('\n')));
  assert.equal(new Set(records.map(r => r.record_key)).size, 2);
}));

const eventsSchema = 'CREATE TABLE assistant_usage_events(id INTEGER, session_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, created_at TEXT)';
const sessionsSchema = 'CREATE TABLE sessions(id TEXT, model TEXT, total_input_tokens INTEGER, total_output_tokens INTEGER, total_cached_tokens INTEGER, total_reasoning_tokens INTEGER, created_at TEXT, updated_at TEXT)';

test('L5 copilot: prefer event sessions, retain summary-only sessions and supersede old totals', async () => fixture(async root => {
  const eventFile = database(join(root, 'session-store.db'), eventsSchema, [
    ['INSERT INTO assistant_usage_events VALUES (?,?,?,?,?,?,?,?,?)', [1, 'shared', 'm', 10, 5, 0, 0, 0, ts]]
  ]);
  const summaryFile = database(join(root, 'data.db'), sessionsSchema, ['shared', 'summary-only'].map(id =>
    ['INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?)', [id, 'm', 10, 5, 0, 0, ts, ts]]));
  const records = [...await collect('copilot', eventFile), ...await collect('copilot', summaryFile)];
  assert.deepEqual(records.map(r => r.session_id).sort(), ['shared', 'summary-only']);
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([{ ...records[0], record_key: 'copilot|shared', kind: 'cumulative', replaces: undefined }]);
    const result = ledger.write.ingestBatch(records);
    assert.equal(result.counts.replaced, 1);
    assert.equal(ledger.read.totals().gross_tokens, 30);
    assert.equal(ledger.write.ingestBatch(records).unchanged, 2);
  } finally { ledger.close(); }
}));

test('L5 openclaw ingestion: shifted archive copies count once and replace persisted old rows', async () => fixture(async root => {
  const keys = ['HOME', 'USERPROFILE', 'OPENCLAW_HOME'];
  const saved = Object.fromEntries(keys.map(k => [k, process.env[k]]));
  const home = join(root, 'home');
  const logs = join(home, '.openclaw');
  const data = join(root, 'data');
  const row = content => ({ session_id: 's', timestamp: ts, message: { role: 'assistant', content, usage: { input: 10, output: 5 } } });
  const active = text(join(logs, 'agents', 'main', 'sessions', 's.jsonl'), [row('first'), row('shared')].map(JSON.stringify).join('\n'));
  const archive = text(join(logs, 'agents', 'main', 'session-sqlite-import-archive', 's.jsonl'), JSON.stringify(row('shared')));
  Object.assign(process.env, { HOME: home, USERPROFILE: home, OPENCLAW_HOME: logs });
  try {
    const ledger = new Ledger(join(data, 'ledger.db'));
    try {
      for (const [file, count] of [[active, 2], [archive, 1]]) {
        ledger.write.ingestBatch(Array.from({ length: count }, (_, i) => ({
          record_key: `openclaw|s|${ts}|${i + 1}`, source: 'openclaw', session_id: 's', kind: 'event', observed_at: ts, input_tokens: 10, output_tokens: 5
        })), { sourceFile: file, parserRev: 2 });
      }
    } finally { ledger.close(); }
    const result = await runIngestion({ dataDir: data });
    assert.equal(result.counts.cross_file_copies, 1);
    assert.equal(result.counts.replaced, 2);
    const check = new Ledger(join(data, 'ledger.db'));
    try { assert.equal(check.read.totals().gross_tokens, 30); }
    finally { check.close(); }
    const again = await runIngestion({ dataDir: data });
    assert.equal(again.inserted + again.updated, 0);
    assert.deepEqual(again.anomalies, []);
  } finally {
    for (const k of keys) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  }
}));
