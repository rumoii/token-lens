import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Ledger } from '../../src/core/db/ledger.js';
import { parseQwen } from '../../src/core/adapters/qwen.js';
import { parserRevOf } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';

for (const authType of ['openai', 'openai-responses', 'qwen-oauth', 'anthropic']) {
  test(`Qwen inclusive auth preserves the thoughts lower bound and diagnoses inconsistent output: ${authType}`, async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'tl-qwen-bound-'));
    try {
      for (const [tokens, output, badFields, zeroUsage] of [
        [{ thoughtsTokens: 120 }, 120, 1, 0],
        [{ outputTokens: null, thoughtsTokens: 120 }, 120, 1, 0],
        [{ outputTokens: 0, thoughtsTokens: 120 }, 0, 1, 1],
        [{ outputTokens: 50, thoughtsTokens: 120 }, 50, 1, 0],
        [{ outputTokens: 120, thoughtsTokens: 120 }, 120, 0, 0],
        [{ outputTokens: 300, thoughtsTokens: 120 }, 300, 0, 0],
        [{ inputTokens: 1000 }, null, 0, 0],
        [{ thoughtsTokens: 0 }, null, 0, 1],
        [{}, null, 0, 1]
      ]) {
        const file = join(tmp, 'usage.jsonl');
        const notes = newNotes();
        writeFileSync(file, JSON.stringify({ id: 'lower-bound', sessionId: 's', authType,
          timestamp: '2026-11-01', ...tokens }));
        const rows = await Array.fromAsync(parseQwen(file, notes));
        assert.equal(rows.length, zeroUsage ? 0 : 1, JSON.stringify(tokens));
        if (rows.length) {
          assert.equal(rows[0].output_tokens, output);
          assert.equal(rows[0].record_key, 'qwen|s|lower-bound');
        }
        assert.deepEqual(notes, { bad_lines: 0, bad_fields: badFields, bad_times: 0, zero_usage: zeroUsage });
      }
    } finally { rmSync(tmp, { recursive: true, force: true }); }
  });
}

for (const [name, overrides, output] of [
  ['OpenAI 服务端 total 不重计 thoughts', { authType: 'openai', totalTokens: 1300 }, 300],
  ['Gemini 分列 thoughts', { authType: 'gemini', totalTokens: 1420 }, 420],
  ['OpenAI 缺 total 后被上游回填', { authType: 'openai', totalTokens: 1420 }, 300],
  ['OpenAI 原始 total 为 0', { authType: 'openai', totalTokens: 0 }, 300],
  ['OpenAI 没有 total', { authType: 'openai' }, 300],
  ['Responses 回填 total', { authType: 'openai-responses', totalTokens: 1420 }, 300],
  ['Qwen OAuth 复用 OpenAI completion', { authType: 'qwen-oauth', totalTokens: 1420 }, 300],
  ['Anthropic completion 不额外加 thoughts', { authType: 'anthropic', totalTokens: 1420 }, 300],
  ['Gemini total 含独立 tool-use prompt', { authType: 'gemini', totalTokens: 1600 }, 420],
  ['Gemini 不用矛盾 total 覆盖分列口径', { authType: 'gemini', totalTokens: 1300 }, 420],
  ['Vertex AI 使用 Gemini 分列口径', { authType: 'vertex-ai', totalTokens: 1300 }, 420],
  ['未知认证仅用完整输入输出的等式判断包含', { totalTokens: 1300 }, 300],
  ['未知认证 total 可能回填，保留分列回退', { totalTokens: 1420 }, 420],
  ['未知认证缺输入时不把 0 当已知输入', { inputTokens: undefined, totalTokens: 300 }, 420],
  ['OpenAI 未知输出保留 thoughts 已知下界', { authType: 'openai', outputTokens: undefined, totalTokens: 1120 }, 120]
]) {
  test(`C2 qwen：${name}`, async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'tl-qwen-c2-'));
    try {
      const file = join(tmp, 'token-usage-c2.jsonl');
      writeFileSync(file, JSON.stringify({ schemaVersion: 1, id: 'event', sessionId: 'session',
        timestamp: '2026-11-01T00:00:00Z', model: 'mimo-v2.6-flash',
        inputTokens: 1000, cachedTokens: 200, outputTokens: 300, thoughtsTokens: 120, ...overrides }));
      const records = await Array.fromAsync(parseQwen(file));
      assert.equal(records.length, 1);
      assert.equal(records[0].output_tokens, output);
      assert.equal(records[0].record_key, 'qwen|session|event');
      assert.equal(records[0].cache_read_tokens, 200);
    } finally { rmSync(tmp, { recursive: true, force: true }); }
  });
}

test('qwen 输出下界语义登记 parser revision 7', () => {
  assert.equal(parserRevOf('qwen'), 7);
});

test('parseQwen should extract schemaVersion 1 camelCase records correctly', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  const filePath = join(tmp, 'token-usage-2026-10.jsonl');

  const lines = [
    JSON.stringify({
      schemaVersion: 1,
      id: 'f4d7f259-e5aa-4240-8dcc-301828b46af6',
      timestamp: '2026-09-30T16:02:18.153Z',
      sessionId: 'sess-qwen-camel',
      model: 'gemini-3.8-flash',
      inputTokens: 140000,
      outputTokens: 500,
      cachedTokens: 100000,
      thoughtsTokens: 800,
      totalTokens: 141300
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseQwen(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'qwen');
  assert.equal(records[0].session_id, 'sess-qwen-camel');
  assert.equal(records[0].model, 'gemini-3.8-flash');
  // 140000 input 扣去 100000 cache = 40000 uncached input
  assert.equal(records[0].input_tokens, 40000);
  // 500 output + 800 thoughts = 1300
  assert.equal(records[0].output_tokens, 1300);
  assert.equal(records[0].cache_read_tokens, 100000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseQwen should support legacy snake_case records', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  const filePath = join(tmp, 'legacy.jsonl');

  const lines = [
    JSON.stringify({
      session_id: 'legacy-sess',
      timestamp: '2026-10-01T10:00:00.000Z',
      model: 'qwen-coder-plus',
      input_tokens: 5000,
      output_tokens: 2000,
      cache_read_tokens: 3000
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseQwen(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'qwen');
  assert.equal(records[0].session_id, 'legacy-sess');
  assert.equal(records[0].input_tokens, 5000);
  assert.equal(records[0].output_tokens, 2000);
  assert.equal(records[0].cache_read_tokens, 3000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseQwen should not double-count thoughtsTokens when totalTokens already includes them', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  try {
    const filePath = join(tmp, 'qwen-total-includes-thoughts.jsonl');

    const lines = [
      // totalTokens = inputTokens + outputTokens，说明 thoughtsTokens 已含在输出里
      JSON.stringify({
        schemaVersion: 1,
        id: 'q-openai',
        sessionId: 's1',
        timestamp: '2026-10-20T01:00:00.000Z',
        model: 'mimo-v2.6-flash',
        authType: 'openai',
        inputTokens: 1000,
        cachedTokens: 200,
        outputTokens: 300,
        thoughtsTokens: 120,
        totalTokens: 1300
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parseQwen(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    assert.equal(records[0].input_tokens, 800);
    assert.equal(records[0].output_tokens, 300);
    assert.equal(records[0].cache_read_tokens, 200);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseQwen should take raw output without thoughts for openai auth when totalTokens is missing', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  try {
    const filePath = join(tmp, 'qwen-openai-no-total.jsonl');

    const lines = [
      JSON.stringify({
        schemaVersion: 1,
        id: 'q-openai-no-total',
        sessionId: 's1',
        timestamp: '2026-10-20T01:00:00.000Z',
        model: 'mimo-v2.6-flash',
        authType: 'openai',
        inputTokens: 1000,
        cachedTokens: 200,
        outputTokens: 300,
        thoughtsTokens: 120
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parseQwen(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    assert.equal(records[0].output_tokens, 300);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseQwen should add thoughtsTokens for gemini auth when totalTokens is missing', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  try {
    const filePath = join(tmp, 'qwen-gemini-no-total.jsonl');

    const lines = [
      JSON.stringify({
        schemaVersion: 1,
        id: 'q-gemini-no-total',
        sessionId: 's1',
        timestamp: '2026-10-20T01:00:00.000Z',
        model: 'mimo-v2.6-flash',
        authType: 'gemini',
        inputTokens: 1000,
        cachedTokens: 200,
        outputTokens: 300,
        thoughtsTokens: 120
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parseQwen(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    assert.equal(records[0].output_tokens, 420);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseQwen should identify records without id by file and line, replacing the ordinal key', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  try {
    const filePath = join(tmp, 'qwen-no-id.jsonl');

    const lines = [
      // 第 1 行有用量，第 2 行是空行，第 3 行有用量：行号按物理行计，空行也算
      JSON.stringify({
        sessionId: 's1',
        timestamp: '2026-10-20T01:00:00.000Z',
        model: 'm1',
        inputTokens: 1,
        outputTokens: 10
      }),
      '',
      JSON.stringify({
        sessionId: 's1',
        timestamp: '2026-10-20T01:01:00.000Z',
        model: 'm1',
        inputTokens: 1,
        outputTokens: 20
      }),
      JSON.stringify({
        id: 'q-id-1',
        sessionId: 's1',
        timestamp: '2026-10-20T01:02:00.000Z',
        model: 'm1',
        inputTokens: 1,
        outputTokens: 30
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parseQwen(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 3);
    assert.match(records[0].record_key, /^qwen\|s1\|f[0-9a-f]{12}:1$/);
    assert.deepEqual(records[0].replaces, ['qwen|s1|#1']);
    assert.match(records[1].record_key, /^qwen\|s1\|f[0-9a-f]{12}:3$/);
    assert.deepEqual(records[1].replaces, ['qwen|s1|#2']);
    assert.equal(records[2].record_key, 'qwen|s1|q-id-1');
    assert.equal(records[2].replaces, undefined);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseQwen should keep both records when one session is split across two files', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  const ledger = new Ledger(':memory:');
  try {
    const line = (ts, outputTokens) => JSON.stringify({
      sessionId: 's1',
      timestamp: ts,
      model: 'm1',
      inputTokens: 1,
      outputTokens
    });

    const fileA = join(tmp, 'token-usage-a.jsonl');
    const fileB = join(tmp, 'token-usage-b.jsonl');
    writeFileSync(fileA, line('2026-10-20T01:00:00.000Z', 10) + '\n', 'utf8');
    writeFileSync(fileB, line('2026-10-20T02:00:00.000Z', 20) + '\n', 'utf8');

    const recordsA = [];
    for await (const r of parseQwen(fileA)) {
      recordsA.push(r);
    }
    const recordsB = [];
    for await (const r of parseQwen(fileB)) {
      recordsB.push(r);
    }

    // 行号身份带各自的文件标签，同一会话分在两个文件里不会撞成一个键
    ledger.write.ingestBatch(recordsA, { sourceFile: fileA, parserRev: 3 });
    ledger.write.ingestBatch(recordsB, { sourceFile: fileB, parserRev: 3 });

    const totals = ledger.read.totals({});
    assert.equal(totals.record_count, 2);
    assert.equal(totals.output_tokens, 30);
  } finally {
    ledger.close();
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 qwen JSONL: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.jsonl'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      sessionId: 's',
      inputTokens: 10,
      outputTokens: 2
    }));
    const records = [];
    for await (const record of parseQwen(join(tmp, 'session-nomodel.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
