import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseCodebuddy } from '../../src/core/adapters/codebuddy.js';
import { discoverAll } from '../../src/core/discovery.js';
import { PARSER_REV } from '../../src/core/adapters/index.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { newNotes } from '../../src/core/adapters/_num.js';

const stamp = 1793491200000;
// Third-party token_stats.rs ab5afe42: usage, ide_request_usage, ide_source.
const cli = (usage = {}) => ({ timestamp: stamp, cwd: 'D:/work/app/', providerData: { model: 'claude-opus-5-5',
  usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 40, cache_creation_input_tokens: 10, ...usage } } });
function fixture(t) {
  const parent = realpathSync(tmpdir()); const root = mkdtempSync(join(parent, 'tl-codebuddy-n5-'));
  const ledger = new Ledger(join(root, 'ledger.db'));
  t.after(() => { ledger.close(); assert.equal(dirname(root), parent); assert.equal(realpathSync(root), root);
    assert.ok(basename(root).startsWith('tl-codebuddy-n5-')); rmSync(root, { recursive: true, force: true }); });
  const file = join(root, 'session.jsonl');
  const put = rows => writeFileSync(file, rows.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join('\n') + '\n');
  const parse = (path = file, notes) => Array.fromAsync(parseCodebuddy(path, notes));
  const ingest = async (path = file) => ledger.write.ingestBatch(await parse(path), { sourceFile: path, parserRev: 4, priceOf: costOf });
  return { root, file, ledger, put, parse, ingest };
}
test('N5 codebuddy CLI: providerData usage, inclusive input, explicit cwd, aliases', async (t) => {
  const f = fixture(t); f.put([cli(), cli({ cache_read_input_tokens: 0, prompt_cache_hit_tokens: 30, prompt_cache_miss_tokens: 70 })]);
  const rows = await f.parse(); assert.equal(rows.length, 2); assert.equal(PARSER_REV.codebuddy, 4);
  assert.deepEqual(rows.map(r => [r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens]), [[60, 20, 40, 10], [70, 20, 30, 10]]);
  assert.equal(rows[0].model, 'claude-opus-5-5'); assert.equal(rows[0].project_key, 'D:\\work\\app');
  assert.equal(rows[0].provider ?? null, null); assert.equal(rows[0].observed_at, '2026-11-01T00:00:00.000Z');
});
test('N5 codebuddy desktop: requests only, startedAt, workspace model and stable request ID', async (t) => {
  const f = fixture(t); const folder = join(f.root, 'history', 'workspace', 'conversation'); mkdirSync(folder, { recursive: true });
  writeFileSync(join(dirname(folder), 'index.json'), JSON.stringify({ conversations: [{ id: 'conversation', selectedModelId: 'claude-opus-5-5' }] }));
  const file = join(folder, 'index.json');
  writeFileSync(file, JSON.stringify({ messages: [{ usage: { inputTokens: 9000 } }], requests: [{ id: 'req1', startedAt: stamp,
    usage: { inputTokens: 100, outputTokens: 20, cacheTokens: 40, cachedWriteTokens: 5 } }] }));
  const [r] = await f.parse(file); assert.equal(r.session_id, 'conversation'); assert.equal(r.record_key, 'codebuddy|conversation|req1');
  assert.equal(r.project_key, null); assert.equal(r.model, 'claude-opus-5-5');
  assert.deepEqual([r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens], [60, 20, 40, 5]);
});
test('N5 codebuddy repeat, same-line growth and append retain ledger identity', async (t) => {
  const f = fixture(t); f.put([cli()]); await f.ingest(); const before = f.ledger.read.totals();
  assert.equal((await f.ingest()).unchanged, 1); assert.deepEqual(f.ledger.read.totals(), before);
  f.put([cli({ input_tokens: 200 }), { ...cli(), timestamp: stamp + 1000 }]);
  const growth = await f.ingest(); assert.equal(growth.updated, 1); assert.equal(growth.inserted, 1);
  // Contract case 4 N/A: CLI rows and IDE requests are request events, no cumulative snapshot.
  assert.equal(f.ledger.read.totals().record_count, 2);
});
test('N5 codebuddy truncation and deleted line keep active usage', async (t) => {
  const f = fixture(t); f.put([cli(), { ...cli(), timestamp: stamp + 1000 }]); await f.ingest(); const before = f.ledger.read.totals();
  // No CLI message ID is verified: preserve positions on truncation, without inventing copy identity.
  f.put([cli()]); const truncated = await f.ingest(); assert.equal(truncated.inserted, 0); assert.equal(truncated.counts.vanished, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
  const db = new DatabaseSync(join(f.root, 'ledger.db'), { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM usage_records WHERE active = 1').get().n, 2); } finally { db.close(); }
  // Request IDs verified in the IDE fixture survive file rotation.
  const a = join(f.root, 'conv', 'index.json'); mkdirSync(dirname(a));
  writeFileSync(a, JSON.stringify({ requests: [{ id: 'r', startedAt: stamp, usage: { inputTokens: 10, outputTokens: 2 } }] }));
  await f.ingest(a); const copy = join(f.root, 'copy', 'conv', 'index.json'); mkdirSync(dirname(copy), { recursive: true }); copyFileSync(a, copy);
  assert.equal((await f.ingest(copy)).inserted, 0);
});
test('N5 codebuddy bad rows and unknown metadata; raw cache-write is separate from miss', async (t) => {
  const f = fixture(t); f.put(['{bad', { ...cli(), timestamp: null }, cli({ input_tokens: -1 }),
    { timestamp: stamp, usage: { prompt_cache_miss_tokens: 10, completion_tokens: 2, prompt_cache_hit_tokens: 4 } },
    { timestamp: stamp, providerData: { usage: { input_tokens: 8, output_tokens: 2 }, rawUsage: { prompt_cache_write_tokens: 3 } } },
    { timestamp: stamp, usage: {} }]);
  const notes = newNotes(); const rows = await f.parse(f.file, notes); assert.equal(rows.length, 3);
  assert.equal(rows[0].input_tokens, null); assert.equal(rows[1].input_tokens, 10); assert.equal(rows[1].cache_write_tokens, null);
  assert.equal(rows[2].cache_write_tokens, 3); assert.equal(rows[2].model, null); assert.equal(rows[2].project_key, null);
  assert.deepEqual(notes, { bad_lines: 1, bad_fields: 1, bad_times: 1, zero_usage: 1 });
  // Contract case 7 N/A: third-party format has no verified independent per-request total.
});
test('N5 codebuddy discovery: projects and IDE conversation index, no guessed roots or bodies', (t) => {
  const f = fixture(t); const keys = ['HOME', 'USERPROFILE', 'LOCALAPPDATA', 'CODEBUDDY_HOME', 'WORKBUDDY_HOME'];
  const saved = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; }));
  Object.assign(process.env, { HOME: f.root, USERPROFILE: f.root, LOCALAPPDATA: join(f.root, 'local'), CODEBUDDY_HOME: join(f.root, 'guess'), WORKBUDDY_HOME: join(f.root, 'guess2') });
  const touch = relative => { const file = join(f.root, relative); mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, '{}'); return file; };
  const expected = ['.codebuddy', '.workbuddy', '.workbuddy-ai'].map(root => touch(`${root}/projects/project/s.jsonl`));
  const base = process.platform === 'win32' ? 'local' : process.platform === 'darwin' ? 'Library/Application Support' : '.local/share';
  expected.push(touch(`${base}/CodeBuddyExtension/Data/uid/CodeBuddyIDE/uid/history/ws/conv/index.json`));
  touch('.codebuddy/sessions/a.jsonl'); touch('.workbuddy/logs/a.json'); touch('guess/projects/a.jsonl');
  touch('.codebuddy/projects/project/subagents/a.jsonl');
  for (const ignored of ['messages', 'check-point', 'backups', 'Public']) touch(`${base}/CodeBuddyExtension/Data/${ignored}/history/ws/conv/index.json`);
  touch(`${base}/CodeBuddyExtension/Data/uid/history/ws/index.json`);
  assert.deepEqual(discoverAll().codebuddy.sort(), expected.sort());
});
