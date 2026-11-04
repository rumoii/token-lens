import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { discoverAll } from '../../src/core/discovery.js';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { newNotes } from '../../src/core/adapters/_num.js';

// AnythingLLM 9caf2b4c: schema.prisma workspace_chats; no workspace foreign key.
const schema = `CREATE TABLE workspace_chats (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, workspaceId INTEGER NOT NULL,
  prompt TEXT NOT NULL, response TEXT NOT NULL, include BOOLEAN NOT NULL DEFAULT true,
  user_id INTEGER, thread_id INTEGER, api_session_id TEXT,
  createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  lastUpdatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  feedbackScore BOOLEAN, memory_processed BOOLEAN
);`;
function fixture(t) {
  const parent = realpathSync(tmpdir()); const root = mkdtempSync(join(parent, 'tl-anythingllm-'));
  const storage = process.platform === 'win32' ? join(root, 'roaming', 'anythingllm-desktop', 'storage')
    : process.platform === 'darwin' ? join(root, 'Library', 'Application Support', 'anythingllm-desktop', 'storage')
      : join(root, '.config', 'anythingllm-desktop', 'storage');
  mkdirSync(storage, { recursive: true });
  const file = join(storage, 'anythingllm.db'); const db = new DatabaseSync(file); db.exec(schema);
  const ledger = new Ledger(join(root, 'ledger.db'));
  t.after(() => { ledger.close(); db.close(); assert.equal(dirname(root), parent); assert.equal(realpathSync(root), root);
    assert.ok(basename(root).startsWith('tl-anythingllm-')); rmSync(root, { recursive: true, force: true }); });
  const put = (id = 1, metrics = {}, { response, include = true, createdAt = 1793491200000 } = {}) => {
    db.prepare('INSERT OR REPLACE INTO workspace_chats (id, workspaceId, prompt, response, include, thread_id, createdAt) VALUES (?, 7, ?, ?, ?, 2, ?)')
      .run(id, '', response ?? JSON.stringify({ metrics: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120,
        model: 'claude-opus-5-5', provider: 'Anthropic', ...metrics } }), Number(include), createdAt);
  };
  const parse = (path = file, notes) => Array.fromAsync(adapters.anythingllm(path, notes));
  const ingest = async (path = file) => ledger.write.ingestBatch(await parse(path), { sourceFile: path, parserRev: 1, priceOf: costOf });
  return { root, file, db, ledger, put, parse, ingest };
}
test('anythingllm collection discovers desktop DB; STORAGE_DIR is not a SQLite override', async (t) => {
  const f = fixture(t); f.put();
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'STORAGE_DIR']; const saved = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; }));
  Object.assign(process.env, { HOME: f.root, USERPROFILE: f.root, APPDATA: join(f.root, 'roaming'), STORAGE_DIR: join(f.root, 'other') });
  mkdirSync(process.env.STORAGE_DIR); copyFileSync(f.file, join(process.env.STORAGE_DIR, 'anythingllm.db'));
  assert.equal((await runIngestion({ dataDir: join(f.root, 'data') })).inserted, 1);
  assert.deepEqual(discoverAll().anythingllm, [f.file]);
});
test('anythingllm normal and include=false: occurred usage counts, cache remains unknown', async (t) => {
  const f = fixture(t); f.put(1, {}, { include: false }); assert.equal(PARSER_REV.anythingllm, 1);
  const [r] = await f.parse();
  assert.equal(r.record_key, 'anythingllm|7|1'); assert.equal(r.session_id, '7|thread:2');
  assert.equal(r.project_key, null); assert.equal(r.model, 'claude-opus-5-5'); assert.equal(r.provider, 'Anthropic');
  assert.equal(r.observed_at, '2026-11-01T00:00:00.000Z'); assert.equal(r.kind, 'event');
  assert.deepEqual([r.input_tokens, r.output_tokens, r.cache_read_tokens, r.cache_write_tokens], [100, 20, null, null]);
});
test('anythingllm repeat, growth and append: ID is independent of tokens', async (t) => {
  const f = fixture(t); f.put(); await f.ingest(); const before = f.ledger.read.totals();
  assert.equal((await f.ingest()).unchanged, 1); assert.deepEqual(f.ledger.read.totals(), before);
  f.put(1, { prompt_tokens: 200 }); f.put(2); const changed = await f.ingest();
  assert.equal(changed.updated, 1); assert.equal(changed.inserted, 1); assert.equal(f.ledger.read.totals().record_count, 2);
  // Contract case 4 N/A: workspace_chats stores response events, no cumulative snapshots.
  f.put(1, { prompt_tokens: 80 }); assert.equal((await f.ingest()).updated, 1);
  assert.equal(f.ledger.read.totals().gross_tokens, 220);
});
test('anythingllm rotation and workspace chat deletion retain active ledger rows', async (t) => {
  const f = fixture(t); f.put(); f.put(2); await f.ingest(); const before = f.ledger.read.totals();
  const rotated = join(f.root, 'copy.db'); copyFileSync(f.file, rotated);
  assert.equal((await f.ingest(rotated)).inserted, 0); await f.ingest();
  // Upstream workspace deletion calls WorkspaceChats.delete({workspaceId}); include=false is only hiding.
  f.db.exec('DELETE FROM workspace_chats WHERE id = 1');
  assert.equal((await f.ingest()).counts.vanished, 1); assert.deepEqual(f.ledger.read.totals(), before);
  const db = new DatabaseSync(join(f.root, 'ledger.db'), { readOnly: true });
  try { assert.equal(db.prepare('SELECT active FROM usage_records WHERE record_key = ?').get('anythingllm|7|1').active, 1); } finally { db.close(); }
  f.db.exec('DELETE FROM workspace_chats WHERE workspaceId = 7'); await f.ingest();
  assert.deepEqual(f.ledger.read.totals(), before);
});
test('anythingllm bad JSON, tokens, times, missing metrics and NULL metadata', async (t) => {
  const f = fixture(t); f.put(1, {}, { response: '{bad' }); f.put(2, {}, { createdAt: 'bad' });
  f.put(3, { prompt_tokens: -1, completion_tokens: '7', model: null, provider: null });
  f.put(4, {}, { response: '{}' }); f.put(5, { prompt_tokens: 0, completion_tokens: 0 });
  const notes = newNotes(); const rows = await f.parse(f.file, notes);
  assert.equal(rows.length, 1); assert.equal(rows[0].input_tokens, null); assert.equal(rows[0].output_tokens, 7);
  assert.equal(rows[0].model, null); assert.equal(rows[0].provider, null);
  assert.deepEqual(notes, { bad_lines: 1, bad_times: 1, bad_fields: 1, zero_usage: 1 });
});
test('anythingllm client total and UTC SQL timestamp; read-only parser preserves DB', async (t) => {
  const f = fixture(t); f.put(1, {}, { createdAt: '2026-11-01 00:00:00' });
  const before = readFileSync(f.file); const mode = f.db.prepare('PRAGMA journal_mode').get();
  const [r] = await f.parse(); assert.equal(r.input_tokens + r.output_tokens, 120);
  assert.equal(r.observed_at, '2026-11-01T00:00:00.000Z');
  assert.deepEqual(readFileSync(f.file), before); assert.deepEqual(f.db.prepare('PRAGMA journal_mode').get(), mode);
  assert.deepEqual(await f.parse(join(f.root, 'missing.db')), []);
  const empty = join(f.root, 'empty.db'); const db = new DatabaseSync(empty); db.close(); assert.deepEqual(await f.parse(empty), []);
});
