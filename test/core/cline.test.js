import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseCline } from '../../src/core/adapters/cline.js';

test('parseCline should extract assistant messages with usage and model', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cline-'));
  const taskDir = join(tmp, 'task-uuid-8899');
  const { mkdirSync } = await import('node:fs');
  mkdirSync(taskDir, { recursive: true });

  const historyPath = join(taskDir, 'api_conversation_history.json');
  const history = [
    { role: 'user', content: 'write a function' },
    {
      role: 'assistant',
      ts: 1784357000000,
      model: 'claude-3-5-sonnet',
      usage: {
        input_tokens: 2500,
        output_tokens: 800,
        cache_read_input_tokens: 1200,
        cache_creation_input_tokens: 300
      }
    }
  ];

  writeFileSync(historyPath, JSON.stringify(history, null, 2), 'utf8');

  const records = [];
  for await (const r of parseCline(historyPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'cline');
  assert.equal(records[0].session_id, 'task-uuid-8899');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 2500);
  assert.equal(records[0].output_tokens, 800);
  assert.equal(records[0].cache_read_tokens, 1200);
  assert.equal(records[0].cache_creation_tokens, 300);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCline should fallback to ui_messages.json when model is missing in api history', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cline-'));
  const taskDir = join(tmp, 'task-uuid-fallback');
  const { mkdirSync } = await import('node:fs');
  mkdirSync(taskDir, { recursive: true });

  const historyPath = join(taskDir, 'api_conversation_history.json');
  const uiMessagesPath = join(taskDir, 'ui_messages.json');

  const uiMessages = [
    {
      type: 'say',
      say: 'api_req_started',
      ts: 1784356990000,
      text: JSON.stringify({ model: 'gpt-4o' })
    }
  ];

  const history = [
    {
      role: 'assistant',
      ts: 1784357000000,
      // 故意缺失 model 字段
      usage: {
        input_tokens: 1000,
        output_tokens: 400
      }
    }
  ];

  writeFileSync(uiMessagesPath, JSON.stringify(uiMessages, null, 2), 'utf8');
  writeFileSync(historyPath, JSON.stringify(history, null, 2), 'utf8');

  const records = [];
  for await (const r of parseCline(historyPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 1000);
  assert.equal(records[0].output_tokens, 400);

  rmSync(tmp, { recursive: true, force: true });
});

test('C4 cline no-ui: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cline-nomodel-'));
  try {
    writeFileSync(join(tmp, 'api_conversation_history.json'), JSON.stringify([
      {
        role: 'assistant',
        ts: 1792960001000,
        usage: {
          input_tokens: 10,
          output_tokens: 2
        }
      }
    ]));
    const records = [];
    for await (const record of parseCline(join(tmp, 'api_conversation_history.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 cline ui-without-model: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cline-nomodel-'));
  try {
    writeFileSync(join(tmp, 'ui_messages.json'), JSON.stringify([{ say: 'api_req_started', ts: 1792960000000, text: '{}' }]));
    writeFileSync(join(tmp, 'api_conversation_history.json'), JSON.stringify([
      {
        role: 'assistant',
        ts: 1792960001000,
        usage: {
          input_tokens: 10,
          output_tokens: 2
        }
      }
    ]));
    const records = [];
    for await (const record of parseCline(join(tmp, 'api_conversation_history.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
