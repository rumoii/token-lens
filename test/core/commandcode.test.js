import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { discoverAll } from '../../src/core/discovery.js';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { newNotes } from '../../src/core/adapters/_num.js';

const stamp = '2026-11-01T00:00:00.000Z';
// command-code 1.88.2: appendMessage, toSessionUsage, estimateCatalogCostUsd.
const header = { type: 'session', version: 3, id: 's1', timestamp: stamp, cwd: 'D:/work/app/' };
const entry = (id = 'a', usage = {}) => ({ type: 'message', id, parentId: null, timestamp: stamp,
  message: { role: 'assistant', content: [] }, model: 'claude-opus-5-5',
  usage: { inputTokens: 100, outputTokens: 20, cacheReadTokens: 40, cacheWriteTokens: 10, ...usage } });

function fixture(t) {
  const parent = realpathSync(tmpdir());
  const root = mkdtempSync(join(parent, 'tl-commandcode-'));
  const ledger = new Ledger(join(root, 'ledger.db'));
  t.after(() => {
    ledger.close();
    assert.equal(dirname(root), parent);
    assert.equal(realpathSync(root), root);
    assert.ok(basename(root).startsWith('tl-commandcode-'));
    rmSync(root, { recursive: true, force: true });
  });
  const file = join(root, '.commandcode', 'projects', 'slug', 's1.jsonl');
  mkdirSync(dirname(file), { recursive: true });
  const put = (rows, head = header) => writeFileSync(file, [head, ...rows].map(x => typeof x === 'string' ? x : JSON.stringify(x)).join('\n') + '\n');
  const parse = (path = file, notes) => Array.fromAsync(adapters.commandcode(path, notes));
  const ingest = async (path = file) => ledger.write.ingestBatch(await parse(path), { sourceFile: path, parserRev: 1, priceOf: costOf });
  return { root, file, ledger, put, parse, ingest };
}

test('commandcode collection discovers transcript and excludes sidecars', async (t) => {
  const f = fixture(t);
  const keys = ['HOME', 'USERPROFILE'];
  const saved = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; }));
  Object.assign(process.env, { HOME: f.root, USERPROFILE: f.root });
  f.put([entry()]);
  for (const suffix of ['meta.json', 'checkpoints.jsonl', 'prompts.jsonl', 'share.json']) copyFileSync(f.file, join(dirname(f.file), `s1.${suffix}`));
  const result = await runIngestion({ dataDir: join(f.root, 'data') });
  assert.equal(result.inserted, 1);
  assert.deepEqual(discoverAll().commandcode, [f.file]);
});

test('commandcode normal: disjoint tokens, entry identity, header cwd, no inferred provider', async (t) => {
  const f = fixture(t); f.put([entry()]);
  assert.equal(PARSER_REV.commandcode, 1);
  const [r] = await f.parse();
  assert.equal(r.record_key, 'commandcode|s1|a');
  assert.equal(r.session_id, 's1');
  assert.equal(r.project_key, 'D:\\work\\app');
  assert.equal(r.model, 'claude-opus-5-5');
  assert.equal(r.provider ?? null, null);
  assert.equal(r.observed_at, stamp);
  assert.equal(r.kind, 'event');
  assert.deepEqual([r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens], [50, 20, 40, 10]);
});

test('commandcode repeat, growth, append and downward event correction preserve identity', async (t) => {
  const f = fixture(t); f.put([entry()]); await f.ingest();
  const before = f.ledger.read.totals();
  assert.equal((await f.ingest()).unchanged, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
  f.put([entry('a', { inputTokens: 200 }), entry('b')]);
  const changed = await f.ingest(); assert.equal(changed.updated, 1); assert.equal(changed.inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
  // Contract case 4 N/A: transcript entries are events, never cumulative session snapshots.
  f.put([entry('a', { inputTokens: 80 }), entry('b')]);
  assert.equal((await f.ingest()).updated, 1);
  assert.equal(f.ledger.read.totals().gross_tokens, 220);
});

test('commandcode rotation and deleted line retain active usage and totals', async (t) => {
  const f = fixture(t); f.put([entry(), entry('b')]); await f.ingest();
  const before = f.ledger.read.totals();
  const rotated = join(f.root, 'rotated.jsonl'); copyFileSync(f.file, rotated);
  assert.equal((await f.ingest(rotated)).inserted, 0);
  await f.ingest(); f.put([entry('b')]);
  assert.equal((await f.ingest()).counts.vanished, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
  const db = new DatabaseSync(join(f.root, 'ledger.db'), { readOnly: true });
  try { assert.equal(db.prepare('SELECT active FROM usage_records WHERE record_key = ?').get('commandcode|s1|a').active, 1); } finally { db.close(); }
});

test('commandcode bad rows, missing metadata and unsupported versions do not invent usage', async (t) => {
  const f = fixture(t);
  f.put(['{bad', { ...entry('no-time'), timestamp: null }, { ...entry(), id: null },
    entry('negative', { inputTokens: 1 }), entry('bad', { outputTokens: -2 }),
    entry('zero', { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 }),
    { type: 'compaction', usage: entry().usage }, { ...entry('user'), message: { role: 'user' } }]);
  const notes = newNotes(); const rows = await f.parse(f.file, notes);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].input_tokens, null);
  assert.equal(rows[1].output_tokens, null);
  assert.deepEqual(notes, { bad_lines: 2, bad_times: 1, bad_fields: 2, zero_usage: 1 });
  f.put([{ ...entry(), model: undefined }], { ...header, cwd: undefined });
  assert.equal((await f.parse())[0].project_key, null);
  assert.equal((await f.parse())[0].model, null);
  f.put([entry()], { ...header, version: 2 });
  assert.deepEqual(await f.parse(), []);
  f.put([entry()], { ...header, id: null });
  assert.deepEqual(await f.parse(), []);
});

test('commandcode unknown caches stay NULL; split and source bytes are preserved', async (t) => {
  const f = fixture(t); f.put([entry('a', { cacheReadTokens: null, cacheWriteTokens: null }), entry('b', { cacheWriteTokens1h: 4 })]);
  const bytes = readFileSync(f.file); const rows = await f.parse();
  assert.equal(rows[0].input_tokens, 100);
  assert.equal(rows[0].cache_read_tokens, null);
  assert.equal(rows[0].cache_write_tokens, null);
  assert.equal(rows[1].cache_write_1h_tokens, 4);
  assert.equal(rows[1].cache_write_5m_tokens, 6);
  assert.deepEqual(readFileSync(f.file), bytes);
  // Contract case 7 N/A: transcript usage has no independent provider total field.
  assert.deepEqual(await f.parse(join(f.root, 'absent.jsonl')), []);
});
