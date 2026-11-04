import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseOpenclaw } from '../../src/core/adapters/openclaw.js';

test('parseOpenclaw should parse assistant usage from jsonl transcript', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-openclaw-'));
  const filePath = join(tmp, 'session-openclaw-101.jsonl');

  const lines = [
    JSON.stringify({
      type: 'message',
      id: 'event-01',
      session_id: 'openclaw-sess-alpha',
      timestamp: '2026-07-07T13:31:00.000Z',
      message: {
        role: 'assistant',
        model: 'claude-opus-4.7',
        usage: {
          input: 1200,
          output: 50,
          cacheRead: 1000,
          cacheWrite: 81071
        }
      }
    }),
    JSON.stringify({ type: 'status', data: 'running' })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseOpenclaw(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'openclaw');
  assert.equal(records[0].session_id, 'openclaw-sess-alpha');
  assert.equal(records[0].model, 'claude-opus-4.7');
  assert.equal(records[0].input_tokens, 1200);
  assert.equal(records[0].output_tokens, 50);
  assert.equal(records[0].cache_read_tokens, 1000);
  assert.equal(records[0].cache_creation_tokens, 81071);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseOpenclaw should gracefully fallback session_id from filename', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-openclaw-'));
  const filePath = join(tmp, 'sess_from_file.jsonl');

  const lines = [
    JSON.stringify({
      message: {
        role: 'assistant',
        model: 'gpt-4o',
        usage: {
          prompt_tokens: 3500,
          completion_tokens: 700
        }
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseOpenclaw(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].session_id, 'sess_from_file');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 3500);
  assert.equal(records[0].output_tokens, 700);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseOpenclaw should ignore non-existent files gracefully', async () => {
  const empty = [];
  for await (const r of parseOpenclaw('non-existent-openclaw.jsonl')) {
    empty.push(r);
  }
  assert.equal(empty.length, 0);
});

test('C4 openclaw JSONL: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-openclaw-nomodel-'));
  try {
    writeFileSync(join(tmp, 'openclaw-model.jsonl'), JSON.stringify({
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
    for await (const record of parseOpenclaw(join(tmp, 'openclaw-model.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
