import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseGrok } from '../../src/core/adapters/grok.js';

test('parseGrok should extract turn_completed usage from updates.jsonl', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-grok-'));
  const summaryPath = join(tmp, 'summary.json');
  const updatesPath = join(tmp, 'updates.jsonl');

  writeFileSync(summaryPath, JSON.stringify({ current_model_id: 'grok-4.7' }), 'utf8');

  const lines = [
    JSON.stringify({
      timestamp: 1784357001,
      method: 'session/update',
      params: {
        sessionId: 'grok-sess-001',
        update: { sessionUpdate: 'agent_thought_chunk' }
      }
    }),
    JSON.stringify({
      timestamp: 1784357002,
      method: 'session/update',
      params: {
        sessionId: 'grok-sess-001',
        update: {
          sessionUpdate: 'turn_completed',
          prompt_id: 'prompt-1',
          usage: {
            inputTokens: 12000,
            outputTokens: 3500,
            cachedReadTokens: 4000,
            cachedWriteTokens: 0
          }
        },
        _meta: { agentTimestampMs: 1784357002000 }
      }
    })
  ];

  writeFileSync(updatesPath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseGrok(updatesPath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'grok');
  assert.equal(records[0].session_id, 'grok-sess-001');
  assert.equal(records[0].model, 'grok-4.7');
  assert.equal(records[0].input_tokens, 12000);
  assert.equal(records[0].output_tokens, 3500);
  assert.equal(records[0].cache_read_tokens, 4000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseGrok should ignore non-completed events', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-grok-'));
  const updatesPath = join(tmp, 'updates.jsonl');

  const lines = [
    JSON.stringify({ method: 'session/update', params: { update: { sessionUpdate: 'something_else' } } })
  ];

  writeFileSync(updatesPath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseGrok(updatesPath)) {
    records.push(r);
  }

  assert.equal(records.length, 0);
  rmSync(tmp, { recursive: true, force: true });
});

test('C4 grok no-summary: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-grok-nomodel-'));
  try {
    writeFileSync(join(tmp, 'updates.jsonl'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      params: {
        sessionId: 's',
        update: {
          sessionUpdate: 'turn_completed',
          usage: {
            inputTokens: 10,
            outputTokens: 2
          }
        }
      }
    }));
    const records = [];
    for await (const record of parseGrok(join(tmp, 'updates.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 grok summary-without-model: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-grok-nomodel-'));
  try {
    writeFileSync(join(tmp, 'summary.json'), '{}');
    writeFileSync(join(tmp, 'updates.jsonl'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      params: {
        sessionId: 's',
        update: {
          sessionUpdate: 'turn_completed',
          usage: {
            inputTokens: 10,
            outputTokens: 2
          }
        }
      }
    }));
    const records = [];
    for await (const record of parseGrok(join(tmp, 'updates.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 grok invalid-summary: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-grok-nomodel-'));
  try {
    writeFileSync(join(tmp, 'summary.json'), '{');
    writeFileSync(join(tmp, 'updates.jsonl'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      params: {
        sessionId: 's',
        update: {
          sessionUpdate: 'turn_completed',
          usage: {
            inputTokens: 10,
            outputTokens: 2
          }
        }
      }
    }));
    const records = [];
    for await (const record of parseGrok(join(tmp, 'updates.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
