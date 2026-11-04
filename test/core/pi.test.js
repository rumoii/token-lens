import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Ledger } from '../../src/core/db/ledger.js';
import { parsePi } from '../../src/core/adapters/pi.js';

test('parsePi should extract assistant message usage from Pi session jsonl', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-'));
  const filePath = join(tmp, '2026-10-01T11-00-00-000Z_01a0f720-test-session.jsonl');

  const lines = [
    JSON.stringify({ type: 'session', version: 3, id: 'pi-session-uuid-1', cwd: 'D:/work/project' }),
    JSON.stringify({ type: 'model_change', provider: 'ollama', modelId: 'qwen:uncensored-4b' }),
    JSON.stringify({
      type: 'message',
      message: {
        role: 'user',
        content: [{ type: 'text', text: 'hello' }]
      }
    }),
    JSON.stringify({
      type: 'message',
      timestamp: '2026-10-01T11:02:30.000Z',
      message: {
        role: 'assistant',
        model: 'qwen:uncensored-4b',
        usage: {
          input: 5000,
          output: 250,
          cacheRead: 1500,
          cacheWrite: 0
        }
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parsePi(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'pi');
  assert.equal(records[0].session_id, 'pi-session-uuid-1');
  assert.equal(records[0].model, 'qwen:uncensored-4b');
  assert.equal(records[0].input_tokens, 5000);
  assert.equal(records[0].output_tokens, 250);
  assert.equal(records[0].cache_read_tokens, 1500);

  rmSync(tmp, { recursive: true, force: true });
});

test('parsePi should ignore non-assistant and zero-usage lines', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-'));
  const filePath = join(tmp, 'empty-pi.jsonl');

  const lines = [
    JSON.stringify({ type: 'session', id: 'empty-1' }),
    JSON.stringify({ type: 'message', message: { role: 'assistant', usage: { input: 0, output: 0 } } })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parsePi(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 0);
  rmSync(tmp, { recursive: true, force: true });
});

test('parsePi should take project_key from the session cwd', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-'));
  try {
    const filePath = join(tmp, '2026-10-01T12-00-00-000Z_01a0f720-project-session.jsonl');

    const lines = [
      JSON.stringify({ type: 'session', version: 3, id: 'pi-session-uuid-2', cwd: 'D:\\work\\app' }),
      JSON.stringify({
        type: 'message',
        timestamp: '2026-10-01T12:02:30.000Z',
        message: {
          role: 'assistant',
          model: 'qwen:uncensored-4b',
          usage: {
            input: 5000,
            output: 250,
            cacheRead: 1500,
            cacheWrite: 0
          }
        }
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parsePi(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    assert.equal(records[0].project_key, 'D:\\work\\app');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parsePi should identify records without id by file and line, replacing the ordinal key', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-'));
  try {
    const filePath = join(tmp, '2026-10-20T01-00-00-000Z_01a0f720-no-id.jsonl');

    const lines = [
      // session 行占第 1 行：两条无 id 记录落在第 2、4 行，第 3 行是空行
      JSON.stringify({ type: 'session', id: 'pi-session-1', cwd: 'D:/work/app' }),
      JSON.stringify({
        type: 'message',
        timestamp: '2026-10-20T01:00:00.000Z',
        message: {
          role: 'assistant',
          model: 'm1',
          usage: { input: 1, output: 10 }
        }
      }),
      '',
      JSON.stringify({
        type: 'message',
        timestamp: '2026-10-20T01:01:00.000Z',
        message: {
          role: 'assistant',
          model: 'm1',
          usage: { input: 1, output: 20 }
        }
      }),
      JSON.stringify({
        type: 'message',
        id: 'msg-pi-1',
        timestamp: '2026-10-20T01:02:00.000Z',
        message: {
          role: 'assistant',
          model: 'm1',
          usage: { input: 1, output: 30 }
        }
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parsePi(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 3);
    assert.match(records[0].record_key, /^pi\|pi-session-1\|f[0-9a-f]{12}:2$/, 'session 行也占物理行号');
    assert.deepEqual(records[0].replaces, ['pi|pi-session-1|#1']);
    assert.match(records[1].record_key, /^pi\|pi-session-1\|f[0-9a-f]{12}:4$/, '行号按物理行计，空行也算');
    assert.deepEqual(records[1].replaces, ['pi|pi-session-1|#2']);
    assert.equal(records[2].record_key, 'pi|pi-session-1|msg-pi-1');
    assert.equal(records[2].replaces, undefined);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parsePi should keep both records when one session is split across two files', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-'));
  const ledger = new Ledger(':memory:');
  try {
    const file = (ts, output) => [
      JSON.stringify({ type: 'session', id: 'pi-split', cwd: 'D:/work/app' }),
      JSON.stringify({
        type: 'message',
        timestamp: ts,
        message: {
          role: 'assistant',
          model: 'm1',
          usage: { input: 1, output }
        }
      })
    ].join('\n') + '\n';

    const fileA = join(tmp, '2026-10-20T01-00-00-000Z_01a0f720-split-a.jsonl');
    const fileB = join(tmp, '2026-10-20T02-00-00-000Z_01a0f720-split-b.jsonl');
    writeFileSync(fileA, file('2026-10-20T01:00:00.000Z', 10), 'utf8');
    writeFileSync(fileB, file('2026-10-20T02:00:00.000Z', 20), 'utf8');

    const recordsA = [];
    for await (const r of parsePi(fileA)) {
      recordsA.push(r);
    }
    const recordsB = [];
    for await (const r of parsePi(fileB)) {
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

test('C4 pi message: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-nomodel-'));
  try {
    writeFileSync(join(tmp, 'pi-agent.jsonl'), JSON.stringify({
      type: 'message',
      timestamp: '2026-10-26T08:30:00.000Z',
      message: {
        role: 'assistant',
        usage: {
          input: 10,
          output: 2
        }
      }
    }));
    const records = [];
    for await (const record of parsePi(join(tmp, 'pi-agent.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 pi: retains logged model changes', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-pi-model-'));
  try {
    const file = join(tmp, 'session.jsonl');
    const message = (model) => ({ type: 'message', timestamp: '2026-10-26T08:30:00.000Z', message: { role: 'assistant', ...(model ? { model } : {}), usage: { input: 10, output: 2 } } });
    writeFileSync(file, [
      message(),
      { type: 'model_change', modelId: 'logged-model' },
      message(),
      message('message-model'),
      { type: 'model_change', model: 'next-logged-model' },
      message()
    ].map(JSON.stringify).join('\n'));
    const records = [];
    for await (const record of parsePi(file)) records.push(record);
    assert.deepEqual(records.map((r) => r.model), [null, 'logged-model', 'message-model', 'next-logged-model']);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
