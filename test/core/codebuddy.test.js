import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { parseCodebuddy } from '../../src/core/adapters/codebuddy.js';

function fixture(t, name) {
  const parent = realpathSync(tmpdir());
  const root = mkdtempSync(join(parent, 'tl-test-codebuddy-'));
  t.after(() => {
    assert.equal(dirname(root), parent); assert.equal(realpathSync(root), root);
    assert.ok(basename(root).startsWith('tl-test-codebuddy-'));
    rmSync(root, { recursive: true, force: true });
  });
  const file = join(root, name); mkdirSync(dirname(file), { recursive: true });
  return file;
}

test('parseCodebuddy reads message.usage before providerData.usage and top-level usage', async (t) => {
  const file = fixture(t, 'session.jsonl');
  writeFileSync(file, JSON.stringify({ timestamp: 1793491200000, providerData: { model: 'hunyuan-code', usage: { input_tokens: 9000 } },
    usage: { input_tokens: 8000 }, message: { role: 'assistant', usage: {
      input_tokens: 2800, output_tokens: 360, cache_read_input_tokens: 1400, cache_write_input_tokens: 180
    } } }));
  const [r] = await Array.fromAsync(parseCodebuddy(file));
  assert.equal(r.source, 'codebuddy'); assert.equal(r.session_id, 'session'); assert.equal(r.model, 'hunyuan-code');
  assert.equal(r.input_tokens, 1400); assert.equal(r.output_tokens, 360);
  assert.equal(r.cache_read_tokens, 1400); assert.equal(r.cache_write_tokens, 180);
});

test('parseCodebuddy reads requests usage from desktop JSON and excludes messages', async (t) => {
  const file = fixture(t, 'conversation/index.json');
  writeFileSync(file, JSON.stringify({ requests: [{ id: 'r1', startedAt: 1793491200000,
    usage: { inputTokens: 3100, outputTokens: 420, cacheTokens: 1600 } }], messages: [{ usage: { inputTokens: 9999 } }] }));
  const records = await Array.fromAsync(parseCodebuddy(file));
  assert.equal(records.length, 1); assert.equal(records[0].session_id, 'conversation');
  assert.equal(records[0].input_tokens, 1500); assert.equal(records[0].output_tokens, 420);
});

test('parseCodebuddy session is the CLI filename, never the per-entry id', async (t) => {
  const file = fixture(t, 'cli-session.jsonl');
  writeFileSync(file, JSON.stringify({ id: 'entry-id', timestamp: 1793491200000, usage: { input_tokens: 1500, output_tokens: 210 } }));
  const [r] = await Array.fromAsync(parseCodebuddy(file)); assert.equal(r.session_id, 'cli-session');
});

test('parseCodebuddy missing file is empty', async () => {
  assert.deepEqual(await Array.fromAsync(parseCodebuddy('non-existent-codebuddy.jsonl')), []);
});

test('C4 codebuddy JSON: missing model stays NULL', async (t) => {
  const file = fixture(t, 'conversation/index.json');
  writeFileSync(file, JSON.stringify({ requests: [{ startedAt: 1793491200000, usage: { inputTokens: 10, outputTokens: 2 } }] }));
  const [r] = await Array.fromAsync(parseCodebuddy(file));
  assert.equal(r.model, null); assert.equal(r.input_tokens, 10); assert.equal(r.output_tokens, 2);
});

test('C4 codebuddy JSONL: missing model stays NULL', async (t) => {
  const file = fixture(t, 'cli-session.jsonl');
  writeFileSync(file, JSON.stringify({ timestamp: 1793491200000, message: { role: 'assistant', usage: { input_tokens: 10, output_tokens: 2 } } }));
  const [r] = await Array.fromAsync(parseCodebuddy(file));
  assert.equal(r.model, null); assert.equal(r.input_tokens, 10); assert.equal(r.output_tokens, 2);
});
