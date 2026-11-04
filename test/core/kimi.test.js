import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseKimi } from '../../src/core/adapters/kimi.js';
import { newNotes } from '../../src/core/adapters/_num.js';

test('parseKimi should parse assistant rounds with usage from jsonl stream', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-'));
  const filePath = join(tmp, 'session-kimi-001.jsonl');

  const lines = [
    JSON.stringify({
      session_id: 'kimi-sess-alpha',
      timestamp: '2026-08-10T08:30:00.000Z',
      message: {
        role: 'assistant',
        model: 'kimi-k2.7-code',
        usage: {
          prompt_tokens: 3200,
          completion_tokens: 450,
          cached_tokens: 1800,
          cache_write_tokens: 250
        }
      }
    }),
    JSON.stringify({
      role: 'user',
      content: '优化这段代码'
    }),
    JSON.stringify({
      session_id: 'kimi-sess-alpha',
      timestamp: '2026-08-10T08:32:00.000Z',
      role: 'assistant',
      model: 'moonshot-v1-32k',
      token_usage: {
        input_tokens: 2100,
        output_tokens: 180
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseKimi(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 2);
  assert.equal(records[0].source, 'kimi');
  assert.equal(records[0].session_id, 'kimi-sess-alpha');
  assert.equal(records[0].model, 'kimi-k2.7-code');
  assert.equal(records[0].input_tokens, 3200);
  assert.equal(records[0].output_tokens, 450);
  assert.equal(records[0].cache_read_tokens, 1800);
  assert.equal(records[0].cache_creation_tokens, 250);

  assert.equal(records[1].model, 'moonshot-v1-32k');
  assert.equal(records[1].input_tokens, 2100);
  assert.equal(records[1].output_tokens, 180);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseKimi should parse structured json session file', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-'));
  const filePath = join(tmp, 'kimi_round_history.json');

  const data = {
    id: 'kimi-conv-9988',
    created_at: '2026-08-11T12:00:00.000Z',
    model: 'moonshot-v1-8k',
    messages: [
      {
        role: 'user',
        content: '解释一下这个算法'
      },
      {
        role: 'assistant',
        model: 'moonshot-v1-8k',
        usage: {
          input: 1500,
          output: 220,
          cached_tokens: 800
        }
      }
    ]
  };

  writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');

  const records = [];
  for await (const r of parseKimi(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'kimi');
  assert.equal(records[0].session_id, 'kimi-conv-9988');
  assert.equal(records[0].model, 'moonshot-v1-8k');
  assert.equal(records[0].input_tokens, 1500);
  assert.equal(records[0].output_tokens, 220);
  assert.equal(records[0].cache_read_tokens, 800);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseKimi should fallback session_id from filename when omitted', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-'));
  const filePath = join(tmp, 'sess_kimi_standalone.jsonl');

  const lines = [
    JSON.stringify({
      role: 'assistant',
      model: 'kimi-k2.7-code',
      usage: {
        prompt_tokens: 900,
        completion_tokens: 95
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseKimi(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].session_id, 'sess_kimi_standalone');

  rmSync(tmp, { recursive: true, force: true });
});

test('parseKimi should handle non-existent file gracefully', async () => {
  const list = [];
  for await (const r of parseKimi('non-existent-kimi.jsonl')) {
    list.push(r);
  }
  assert.equal(list.length, 0);
});

test('parseKimi should parse Kimi Code usage records for main and subagents', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-code-'));
  const sessionId = '123e4567-e89b-12d3-a456-426614174000';
  const session = join(tmp, '.kimi-code', 'sessions', 'wd_demo', `session_${sessionId}`, 'agents');
  const mainFile = join(session, 'main', 'wire.jsonl');
  const subagentFile = join(session, 'agent-0', 'wire.jsonl');
  const time = 1792837364515;
  const usage = { inputOther: 100, output: 20, inputCacheRead: 30, inputCacheCreation: 4 };
  const mainRows = [
    { type: 'metadata', protocol_version: '1.5' },
    { type: 'usage.record', agentId: 'main', model: 'kimi-code/k3.1-pro', usage, usageScope: 'turn', time },
    { type: 'usage.record', agentId: 'main', model: 'kimi-code/k3.1-pro', usage: { inputOther: 200, output: 40, inputCacheRead: 50, inputCacheCreation: 6 }, usageScope: 'session', time: time + 1000 },
    { type: 'usage.record', agentId: 'main', model: 'kimi-code/k3.1-pro', usage: { inputOther: 0, output: 0, inputCacheRead: 0, inputCacheCreation: 0 }, usageScope: 'turn', time: time + 2000 }
  ];

  const collect = async (file, notes = newNotes()) => {
    const records = [];
    for await (const record of parseKimi(file, notes)) records.push(record);
    return { records, notes };
  };

  try {
    mkdirSync(join(session, 'main'), { recursive: true });
    mkdirSync(join(session, 'agent-0'), { recursive: true });
    writeFileSync(mainFile, mainRows.map(JSON.stringify).join('\n') + '\n', 'utf8');
    writeFileSync(subagentFile, JSON.stringify({ type: 'usage.record', agentId: 'agent-0', usage, usageScope: 'turn', time }) + '\n', 'utf8');

    const main = await collect(mainFile);
    const subagent = await collect(subagentFile);
    assert.equal(main.records.length, 2, 'turn 与会话压缩调用都应计入');
    assert.equal(main.notes.zero_usage, 1);
    assert.equal(main.records[0].session_id, sessionId);
    assert.equal(main.records[0].model, 'kimi-code/k3.1-pro');
    assert.equal(main.records[0].observed_at, new Date(time).toISOString());
    assert.equal(main.records[0].input_tokens, 100);
    assert.equal(main.records[0].output_tokens, 20);
    assert.equal(main.records[0].cache_read_tokens, 30);
    assert.equal(main.records[0].cache_write_tokens, 4);
    assert.equal(subagent.records[0].model, null);
    assert.notEqual(main.records[0].record_key, subagent.records[0].record_key);
    assert.deepEqual((await collect(mainFile)).records.map((r) => r.record_key), main.records.map((r) => r.record_key));

    writeFileSync(subagentFile, JSON.stringify({ type: 'usage.record', agentId: 'agent-0', usage, usageScope: 'turn', time: time + 1 }) + '\n', 'utf8');
    const rewritten = await collect(subagentFile);
    assert.notEqual(rewritten.records[0].record_key, subagent.records[0].record_key, 'wire 截断后复用同一行的新调用不能继承旧身份');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('Kimi Code wire：subagent.completed 的汇总不另计，子 agent 的用量只来自它自己的 usage.record', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-'));
  const session = join(tmp, '.kimi-code', 'sessions', 'wd_x', 'session_s1', 'agents');
  const mainFile = join(session, 'main', 'wire.jsonl');
  mkdirSync(join(session, 'main'), { recursive: true });
  writeFileSync(mainFile, [
    { type: 'usage.record', agentId: 'main', model: 'kimi-code/k3.1-pro', usage: { inputOther: 10, output: 2, inputCacheRead: 30, inputCacheCreation: 0 }, usageScope: 'turn', time: 1792831480000 },
    { type: 'subagent.completed', subagentId: 'agent-1', usage: { inputOther: 59157, output: 5475, inputCacheRead: 94208, inputCacheCreation: 0 }, contextTokens: 68503, time: 1792831484751 }
  ].map((row) => JSON.stringify(row)).join('\n'));
  try {
    const records = [];
    for await (const record of parseKimi(mainFile, newNotes())) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].session_id, 's1');
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('Kimi 通用 JSONL：缺模型存 NULL，不猜 moonshot-v1-8k', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-kimi-'));
  const filePath = join(tmp, 'session-kimi-nomodel.jsonl');
  writeFileSync(filePath, JSON.stringify({
    session_id: 's', timestamp: '2026-08-10T08:30:00.000Z',
    message: { role: 'assistant', usage: { prompt_tokens: 10, completion_tokens: 2 } }
  }));
  try {
    const records = [];
    for await (const record of parseKimi(filePath, newNotes())) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
