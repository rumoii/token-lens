import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { zstdCompressSync } from 'node:zlib';
import { aggregate } from './common.mjs';
import { oracle as claude } from './claude.mjs';
import { oracle as codex } from './codex.mjs';
import { oracle as qwen } from './qwen.mjs';
import { parseQwen } from '../../../src/core/adapters/qwen.js';
import { oracle as dsh } from './dsh.mjs';
import { oracle as pi } from './pi.mjs';
import { oracle as kimi } from './kimi.mjs';
import { mkdirSync } from 'node:fs';
import { compareSessions, parseArgs, validatePaths } from '../oracle-compare.mjs';

const directory = mkdtempSync(join(tmpdir(), 'tl-oracle-test-'));
function jsonl(name, rows) {
  const file = join(directory, name);
  writeFileSync(file, rows.map(row => typeof row === 'string' ? row : JSON.stringify(row)).join('\n'));
  return file;
}
const usage = (output = 3) => ({ input_tokens: 2, output_tokens: output, cache_read_input_tokens: 8, cache_creation_input_tokens: 1 });

for (const authType of ['openai', 'openai-responses', 'qwen-oauth', 'anthropic', 'gemini', 'vertex-ai', 'unknown', undefined]) {
  test(`Qwen shared corpus: field aliases and numeric values (${authType ?? 'missing auth'})`, async () => {
    // Each tuple supplies independent expectations: input, raw output, cache read, cache write.
    const corpus = [
      [{ inputTokens: 1000, outputTokens: 300, cachedTokens: 200, cacheWriteTokens: 10 }, [800, 300, 200, 10]],
      [{ input_tokens: 1000, output_tokens: 300, cached_tokens: 200, cache_write_tokens: 10 }, [1000, 300, 200, 10]],
      [{ input_tokens: 1000, outputTokens: 300, cached_tokens: 200, cacheWriteTokens: 10 }, [1000, 300, 200, 10]],
      [{ prompt_tokens: 1000, completion_tokens: 300, cache_read_tokens: 200, cache_creation_tokens: 10 }, [1000, 300, 200, 10]],
      [{ inputTokens: ' 1000 ', output_tokens: '300', cached_tokens: '0200', cache_creation_tokens: '10' }, [800, 300, 200, 10]],
      [{ inputTokens: null, input_tokens: 1000, outputTokens: null, completion_tokens: 300,
        cachedTokens: null, cached_tokens: 200, cacheWriteTokens: null, cache_creation_tokens: 10 }, [800, 300, 200, 10]],
      [{ inputTokens: 1000, input_tokens: 9999, outputTokens: 300, output_tokens: 9999,
        cachedTokens: 200, cached_tokens: 9999, cacheWriteTokens: 10, cache_write_tokens: 9999 }, [800, 300, 200, 10]],
      [{ inputTokens: 0, input_tokens: 9999, outputTokens: 0, completion_tokens: 9999,
        cachedTokens: 0, cache_read_tokens: 9999, cacheWriteTokens: 10, cache_creation_tokens: 9999 }, [0, 0, 0, 10]],
      [{ inputTokens: 1000, outputTokens: 300 }, [1000, 300, null, null]],
      [{ inputTokens: 100, outputTokens: 300, cachedTokens: 200 }, [0, 300, 200, null]],
      [{ inputTokens: 'invalid', input_tokens: 1000, outputTokens: 300 }, [null, 300, null, null]],
      [{ inputTokens: '1e3', input_tokens: 1000, outputTokens: 300 }, [null, 300, null, null]],
      [{ inputTokens: -1, input_tokens: 1000, outputTokens: 300 }, [null, 300, null, null]],
      [{ inputTokens: 1.5, input_tokens: 1000, outputTokens: 300 }, [null, 300, null, null]]
    ];
    for (const total of [1300, 1420, '1300']) {
      const rows = corpus.map(([tokens], index) => ({ id: `${total}-${index}`, sessionId: 'shared',
        timestamp: '2026-11-01', thoughts_tokens: '120', totalTokens: total, authType, ...tokens }));
      const file = jsonl(`qwen-shared-${authType}-${typeof total}-${total}.jsonl`, rows);
      const actual = await Array.fromAsync(parseQwen(file));
      const result = await qwen({ files: [file] });
      assert.equal(result.entries.length, rows.length);
      assert.equal(actual.length, rows.length);
      for (let index = 0; index < rows.length; index++) {
        const a = actual[index], b = result.entries[index];
        assert.equal(b.raw.id, rows[index].id);
        assert.deepEqual([b.input, b.output, b.cache_read, b.cache_write],
          [a.input_tokens, a.output_tokens, a.cache_read_tokens, a.cache_write_tokens], `row ${index}, total ${total}`);
        const [input, output, cached, written] = corpus[index][1];
        assert.deepEqual([a.input_tokens, a.cache_read_tokens, a.cache_write_tokens], [input, cached, written]);
        const inclusive = ['openai', 'openai-responses', 'qwen-oauth', 'anthropic'].includes(authType)
          || (!['gemini', 'vertex-ai'].includes(authType) && total === 1300 && (index < 7 || index === 8));
        assert.equal(a.output_tokens, inclusive ? output : output + 120);
      }
    }
  });
}

test('Claude keeps last streaming snapshot and gives copies to the earliest file', async () => {
  const first = jsonl('z-original.jsonl', [
    { sessionId: 'original', timestamp: '2026-01-01T00:00:00Z', message: { id: 'm', usage: usage(1) } },
    '', '{broken',
    { sessionId: 'original', timestamp: '2026-01-01T00:01:00Z', message: { id: 'm', usage: usage(4) } }
  ]);
  const second = jsonl('a-copy.jsonl', [{ sessionId: 'fork', timestamp: '2026-01-01T00:02:00Z', message: { id: 'm', usage: usage(9) } }]);
  const result = await claude({ files: [second, first] });
  assert.equal(result.entries.length, 1);
  assert.equal(result.entries[0].session_id, 'original');
  assert.equal(result.entries[0].output, 4);
  assert.equal(result.entries[0].line, 4);
  assert.equal(result.issues[0].type, 'bad_json');
  assert.equal(result.duplicates.filter(row => row.type === 'snapshot').length, 1);
  assert.equal(result.duplicates.filter(row => row.type === 'cross_file_copy').length, 1);
});

test('Claude UUID fallback merges copies; path order resolves equal starts', async () => {
  const row = { uuid: 'u', timestamp: '2026-01-01T00:00:00Z', message: { usage: usage() } };
  const b = jsonl('b.jsonl', [{ ...row, sessionId: 'b' }]);
  const a = jsonl('a.jsonl', [{ ...row, sessionId: 'a' }]);
  assert.equal((await claude({ files: [b, a] })).entries[0].session_id, 'a');
});

test('inclusive inputs, thoughts and unknown counts stay distinct from zero', async () => {
  const file = jsonl('qwen.jsonl', [
    { id: 'a', sessionId: 's', timestamp: '2026-01-01', inputTokens: 10, outputTokens: 2, thoughtsTokens: 3, cachedTokens: 7 },
    { id: 'b', sessionId: 's', timestamp: '2026-01-01', inputTokens: 10, outputTokens: 2, thoughtsTokens: 0 }
  ]);
  const result = await qwen({ files: [file] });
  assert.equal(result.sessions[0].input, 13);
  assert.equal(result.sessions[0].output, 7);
  assert.equal(result.sessions[0].cache_write, null);
  assert.deepEqual(result.sessions[0].unknown, { input: 0, output: 0, cache_read: 1, cache_write: 2 });
});

test('Codex decodes concatenated frames and does not count repeated cumulative notices', async () => {
  const raw = { input_tokens: 12, output_tokens: 3, cached_input_tokens: 8, total_tokens: 15 };
  const notice = { type: 'event_msg', payload: { type: 'token_count', info: { last_token_usage: raw, total_token_usage: raw } } };
  const first = JSON.stringify({ type: 'session_meta', payload: { id: 's' } }) + '\n';
  const second = [
    { type: 'token_usage_record', timestamp: '2026-01-01', payload: { session_id: 's', response_id: 'r', usage: raw } }, notice, notice
  ].map(row => JSON.stringify(row)).join('\n');
  const file = join(directory, 'rollout.jsonl.zst');
  writeFileSync(file, Buffer.concat([zstdCompressSync(first), zstdCompressSync(second)]));
  const result = await codex({ files: [file] });
  assert.equal(result.entries[0].input, 4);
  assert.equal(result.entries[0].cache_write, null);
  assert.equal(result.cross_checks[0].repeated_token_count, 1);
  assert.deepEqual(Object.values(result.cross_checks[0].usage_minus_total), [0, 0, 0, 0]);
  assert.deepEqual(Object.values(result.cross_checks[0].last_minus_total), [0, 0, 0, 0]);
});

test('DSH takes newest cumulative snapshot and preserves legitimate uncached zero', async () => {
  const rows = ended => ({ record: { identity: 's', rows: { tokenUsage: { val: { totals: {
    uncachedInputTokens: 0, inputTokens: 999, outputTokens: ended, cacheReadTokens: 10
  } } }, timeContext: { val: { lastMessageTime: ended } } } } });
  const dirA = join(directory, 'dsh-old'), dirB = join(directory, 'dsh-new');
  mkdirSync(dirA); mkdirSync(dirB);
  const a = join(dirA, 'session-s.json'), b = join(dirB, 'session-s.json');
  writeFileSync(a, JSON.stringify(rows(1000)));
  writeFileSync(b, JSON.stringify(rows(2000)));
  const result = await dsh({ files: [b, a] });
  assert.equal(result.entries.length, 1);
  assert.equal(result.entries[0].input, 0);
  assert.equal(result.entries[0].output, 2000);
  assert.equal(result.entries[0].cache_write, null);
});

for (const [name, authType, totalTokens, expected] of [
  ['openai', 'openai', 1300, 300],
  ['gemini', 'gemini', 1420, 420],
  ['openai-fallback', 'openai', 1420, 300],
  ['openai-zero-total', 'openai', 0, 300],
  ['openai-no-total', 'openai', undefined, 300],
  ['responses', 'openai-responses', 1420, 300],
  ['oauth', 'qwen-oauth', 1420, 300],
  ['anthropic', 'anthropic', 1420, 300],
  ['gemini-tool-prompt', 'gemini', 1600, 420],
  ['gemini-unreliable-total', 'gemini', 1300, 420],
  ['vertex', 'vertex-ai', 1300, 420],
  ['unknown-inclusive', undefined, 1300, 300],
  ['unknown-fallback', undefined, 1420, 420]
]) {
  test(`C2 independent Qwen output semantics: ${name}`, async () => {
    const file = jsonl(`qwen-c2-${name}.jsonl`, [{ id: name, sessionId: 's', timestamp: '2026-11-01',
      inputTokens: 1000, cachedTokens: 200, outputTokens: 300, thoughtsTokens: 120, authType, totalTokens }]);
    assert.equal((await qwen({ files: [file] })).entries[0].output, expected);
  });
}

test('independent Qwen preserves the thoughts lower bound and requires known input for the total equality', async () => {
  const file = jsonl('qwen-c2-unknowns.jsonl', [
    { id: 'a', sessionId: 's', timestamp: '2026-11-01', authType: 'openai', inputTokens: 1000, thoughtsTokens: 120, totalTokens: 1120 },
    { id: 'b', sessionId: 's', timestamp: '2026-11-01', outputTokens: 300, thoughtsTokens: 120, totalTokens: 300 }
  ]);
  assert.deepEqual((await qwen({ files: [file] })).entries.map(row => row.output), [120, 420]);
});

for (const authType of ['openai', 'openai-responses', 'qwen-oauth', 'anthropic']) {
  test(`Qwen shared corpus: lower bounds and diagnostics (${authType})`, async () => {
    const rows = [
      { thoughtsTokens: 120 },
      { outputTokens: null, thoughts_tokens: '120' },
      { output_tokens: 0, thoughtsTokens: 120 },
      { completion_tokens: 50, thoughtsTokens: 120 },
      { outputTokens: 120, thoughtsTokens: 120 },
      { outputTokens: 300, thoughtsTokens: 120 },
      { inputTokens: 1000 },
      { thoughtsTokens: 0 },
      {},
      { cached_tokens: 10 },
      { cache_creation_tokens: 10 }
    ].map((tokens, index) => ({ id: `bound-${index}`, sessionId: 'shared', timestamp: '2026-11-01', authType, ...tokens }));
    const file = jsonl(`qwen-bounds-${authType}.jsonl`, rows);
    const actual = await Array.fromAsync(parseQwen(file));
    const result = await qwen({ files: [file] });
    assert.deepEqual(result.issues.map(({ type, line }) => ({ type, line })),
      [1, 2, 3, 4].map(line => ({ type: 'bad_fields', line })));
    assert.deepEqual(result.entries.map(row => row.raw.id), ['bound-0', 'bound-1', 'bound-3', 'bound-4', 'bound-5', 'bound-6', 'bound-9', 'bound-10']);
    assert.deepEqual(result.entries.map(row => row.output), [120, 120, 50, 120, 300, null, null, null]);
    assert.deepEqual(result.entries.map(row => [row.input, row.output, row.cache_read, row.cache_write]),
      actual.map(row => [row.input_tokens, row.output_tokens, row.cache_read_tokens, row.cache_write_tokens]));
  });
}

test('C2 DSH uses the filename, removes exactly one leading session- and ignores identity as an ID', async () => {
  for (const [stem, identity, expected] of [
    ['session-id', { createdAt: 1793491200000 }, 'id'],
    ['session-session-id', { createdAt: 1793491200000 }, 'session-id'],
    ['plain-id', 'conflicting-identity', 'plain-id']
  ]) {
    const file = join(directory, `${stem}.json`);
    writeFileSync(file, JSON.stringify({ record: { identity, rows: { tokenUsage: { val: { totals: { uncachedInputTokens: 1, outputTokens: 2 } } } } } }));
    const result = await dsh({ files: [file] });
    assert.equal(result.entries[0].session_id, expected);
    assert.equal(result.issues.some(issue => issue.type === 'session_filename_prefix'), false);
  }
});

test('Codex localizes responses absent from cumulative updates without suppressing raw last usage', async () => {
  const first = { input_tokens: 12, output_tokens: 3, cached_input_tokens: 8, total_tokens: 15 };
  const extra = { input_tokens: 20, output_tokens: 5, cached_input_tokens: 10, total_tokens: 25 };
  const last = { input_tokens: 0, output_tokens: 0, cached_input_tokens: 0, total_tokens: 9 };
  const file = jsonl('cross-check.jsonl', [
    { type: 'session_meta', payload: { id: 's' } },
    { type: 'token_usage_record', timestamp: '2026-01-01', payload: { session_id: 's', response_id: 'a', usage: first } },
    { type: 'event_msg', payload: { type: 'token_count', info: { last_token_usage: first, total_token_usage: first } } },
    { type: 'token_usage_record', timestamp: '2026-01-02', payload: { session_id: 's', response_id: 'b', usage: extra } },
    { type: 'event_msg', payload: { type: 'token_count', info: { last_token_usage: last, total_token_usage: first } } }
  ]);
  const result = await codex({ files: [file] });
  const check = result.cross_checks[0];
  assert.equal(check.raw_last_minus_total.total_tokens, 9);
  assert.equal(check.usage_minus_total.total_tokens, 25);
  assert.equal(check.unreflected_responses[0].response_id, 'b');
  assert.equal(check.unreflected_responses[0].line, 4);
  assert.equal(check.residual_after_unreflected.total_tokens, 0);
});

test('Pi preserves session-scoped ids and records copied-history candidates and zero events', async () => {
  const u = { input: 10, output: 2, cacheRead: 3, cacheWrite: 0 };
  const file = session => jsonl(`pi-${session}.jsonl`, [{ type: 'session', id: session },
    { type: 'message', id: 'm', timestamp: '2026-01-01', message: { role: 'assistant', usage: u } },
    { type: 'message', id: 'zero', timestamp: '2026-01-02', message: { usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } } }]);
  const result = await pi({ files: [file('a'), file('b')] });
  assert.equal(result.entries.length, 4);
  assert.equal(result.copy_candidates.length, 2);
  assert.equal(result.sessions[0].records, 2);
});

test('compare detects absent sessions, token differences, and unknown vs explicit zero', () => {
  const base = { source: 'qwen', session_id: 's', input: 1, output: 2, cache_read: 3, cache_write: null };
  const expected = aggregate([base]);
  const actual = aggregate([{ ...base, cache_write: 0 }]);
  const diff = compareSessions(expected, actual)[0];
  assert.equal(diff.equal, false);
  assert.deepEqual(diff.differences.map(row => row.field), ['cache_write', 'cache_write_unknown']);
  assert.equal(compareSessions(expected, [])[0].differences[0].field, 'presence');
  assert.equal(compareSessions(expected, expected)[0].equal, true);
});

test('CLI requires explicit fresh output paths and rejects installed-directory spelling before opening it', () => {
  assert.throws(() => parseArgs(['--out', directory]), /必须指定/);
  assert.throws(() => parseArgs(['--source', 'other', '--out', directory, '--data-dir', directory]), /来源/);
  assert.throws(() => validatePaths({ dataDir: join(directory, '.token-lens'), out: join(directory, 'reports') }, directory), /禁止/);
  assert.throws(() => validatePaths({ dataDir: directory, out: `${directory}-reports` }, `${directory}-home`), /全新|不存在或为空/);
});

test('Kimi wire counts every usage.record per session and checks the client-measured total', async () => {
  const dir = join(directory, 'kimi', 'wd_x', 'session_abc', 'agents', 'agent-0');
  mkdirSync(dir, { recursive: true });
  const file = join(dir, 'wire.jsonl');
  writeFileSync(file, [
    { type: 'usage.record', agentId: 'agent-0', model: 'm', usage: { inputOther: 5, output: 2, inputCacheRead: 10, inputCacheCreation: 0 }, usageScope: 'turn', time: 1793019702596 },
    { type: 'token_counting.measured', agentId: 'agent-0', tokens: 17, time: 1793019702596 },
    { type: 'usage.record', agentId: 'agent-0', model: 'm', usage: { inputOther: 1, output: 1, inputCacheRead: 0 }, usageScope: 'session', time: 1793019709000 },
    { type: 'token_counting.measured', agentId: 'agent-0', tokens: 9, time: 1793019709000 }
  ].map(row => JSON.stringify(row)).join('\n'));
  const result = await kimi({ files: [file] });
  assert.equal(result.entries.length, 2);
  assert.deepEqual(result.sessions.map(row => [row.session_id, row.records, row.input, row.cache_write, row.unknown.cache_write]), [['abc', 2, 6, 0, 1]]);
  assert.deepEqual(result.cross_checks.map(row => [row.type, row.ok]), [['measured_total', true], ['measured_total', false]]);
});
