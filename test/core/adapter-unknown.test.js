import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseQwen } from '../../src/core/adapters/qwen.js';
import { parsePi } from '../../src/core/adapters/pi.js';
import { parseAider } from '../../src/core/adapters/aider.js';
import { parseDsh } from '../../src/core/adapters/dsh.js';
import { parseGrok } from '../../src/core/adapters/grok.js';
import { parseGemini } from '../../src/core/adapters/gemini.js';
import { newNotes } from '../../src/core/adapters/_num.js';

async function withFile(name, content, parse) {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapter-unknown-'));
  try {
    const file = join(dir, name);
    writeFileSync(file, content);
    const notes = newNotes();
    const records = [];
    for await (const record of parse(file, notes)) records.push(record);
    return { records, notes };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function assertUnknownCache(record) {
  assert.equal(record.cache_read_tokens, null);
  assert.equal(record.cache_write_tokens, null);
}

test('qwen：缺失缓存是未知，合法零输入不会借用其他字段', async () => {
  const line = JSON.stringify({ id: 'q1', inputTokens: 4, outputTokens: 2, totalTokens: 6, timestamp: '2026-10-20T01:00:00Z' });
  const { records } = await withFile('q.jsonl', line + '\n', parseQwen);
  assert.equal(records.length, 1);
  assert.equal(records[0].input_tokens, 4);
  assertUnknownCache(records[0]);
});

test('pi：缺失缓存是未知并统计零用量', async () => {
  const rows = [
    { type: 'message', id: 'p1', timestamp: '2026-10-20T01:00:00Z', message: { role: 'assistant', usage: { input: 3, output: 2 } } },
    { type: 'message', id: 'p2', timestamp: '2026-10-20T01:01:00Z', message: { role: 'assistant', usage: {} } }
  ];
  const { records, notes } = await withFile('p.jsonl', rows.map(JSON.stringify).join('\n') + '\n', parsePi);
  assert.equal(records.length, 1);
  assertUnknownCache(records[0]);
  assert.equal(notes.zero_usage, 1);
});

test('aider：缺失缓存是未知，OpenAI 输入扣减保持原语义', async () => {
  const line = JSON.stringify({ timestamp: '2026-10-20T01:00:00Z', usage: { prompt_tokens: 8, completion_tokens: 2, cached_tokens: 3 } });
  const { records } = await withFile('a.jsonl', line + '\n', parseAider);
  assert.equal(records[0].input_tokens, 5);
  assert.equal(records[0].cache_read_tokens, 3);
  assert.equal(records[0].cache_write_tokens, null);
});

test('dsh：缺失总量字段是未知，坏 JSON 作为读取失败抛出', async () => {
  const data = { record: { identity: { createdAt: '2026-10-20T01:00:00Z' }, rows: { tokenUsage: { val: { totals: { uncachedInputTokens: 0, inputTokens: 9, outputTokens: 2 } } } } } };
  const { records } = await withFile('d.json', JSON.stringify(data), parseDsh);
  assert.equal(records[0].input_tokens, 0);
  assertUnknownCache(records[0]);
  await assert.rejects(withFile('bad.json', '{bad', parseDsh), SyntaxError);
});

test('grok：缺失缓存是未知', async () => {
  const line = JSON.stringify({ timestamp: '2026-10-20T01:00:00Z', params: { sessionId: 'g', update: { sessionUpdate: 'turn_completed', turnId: 't1', usage: { inputTokens: 4, outputTokens: 2 } } } });
  const { records } = await withFile('updates.jsonl', line + '\n', parseGrok);
  assertUnknownCache(records[0]);
});

test('gemini：缺失缓存是未知，坏 JSON 作为读取失败抛出', async () => {
  const data = { id: 'g', startTime: '2026-10-20T01:00:00Z', usageMetadata: { promptTokenCount: 4, candidatesTokenCount: 2 } };
  const { records } = await withFile('g.json', JSON.stringify(data), parseGemini);
  assertUnknownCache(records[0]);
  await assert.rejects(withFile('bad.json', '{bad', parseGemini), SyntaxError);
});
