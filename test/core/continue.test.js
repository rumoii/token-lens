import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseContinue } from '../../src/core/adapters/continue.js';

test('parseContinue should extract assistant rounds with usage from session json', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-continue-'));
  const filePath = join(tmp, 'continue-sess-001.json');

  const mockSession = {
    sessionId: 'sess-continue-uuid',
    title: 'create auth middleware',
    dateCreated: '2026-10-10T12:00:00.000Z',
    modelTitle: 'claude-3-5-sonnet',
    history: [
      {
        role: 'user',
        message: { content: 'hello' }
      },
      {
        role: 'assistant',
        timestamp: '2026-10-10T12:00:05.000Z',
        modelTitle: 'claude-3-5-sonnet',
        promptTokens: 4500,
        completionTokens: 850,
        cachedTokens: 1200
      }
    ]
  };

  writeFileSync(filePath, JSON.stringify(mockSession, null, 2), 'utf8');

  const records = [];
  for await (const r of parseContinue(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'continue');
  assert.equal(records[0].session_id, 'sess-continue-uuid');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 4500);
  assert.equal(records[0].output_tokens, 850);
  assert.equal(records[0].cache_read_tokens, 1200);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseContinue should fallback to session-level tokenCount when history has no usage', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-continue-'));
  const filePath = join(tmp, 'continue-sess-top.json');

  const mockSession = {
    sessionId: 'sess-continue-top',
    modelTitle: 'gpt-4o',
    dateCreated: '2026-10-10T13:00:00.000Z',
    history: [{ role: 'assistant', message: { content: 'test' } }],
    tokenCount: {
      input: 3000,
      output: 500
    }
  };

  writeFileSync(filePath, JSON.stringify(mockSession, null, 2), 'utf8');

  const records = [];
  for await (const r of parseContinue(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'continue');
  assert.equal(records[0].session_id, 'sess-continue-top');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 3000);
  assert.equal(records[0].output_tokens, 500);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseContinue should ignore empty or non-existent files gracefully', async () => {
  const empty = [];
  for await (const r of parseContinue('non-existent-continue.json')) {
    empty.push(r);
  }
  assert.equal(empty.length, 0);
});

test('C4 continue history: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-continue-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.json'), JSON.stringify({
      dateCreated: '2026-10-26T08:30:00.000Z',
      history: [
        {
          role: 'assistant',
          promptTokens: 10,
          completionTokens: 2
        }
      ]
    }));
    const records = [];
    for await (const record of parseContinue(join(tmp, 'session-nomodel.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 continue summary: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-continue-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.json'), JSON.stringify({
      dateCreated: '2026-10-26T08:30:00.000Z',
      tokenCount: {
        input: 10,
        output: 2
      }
    }));
    const records = [];
    for await (const record of parseContinue(join(tmp, 'session-nomodel.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
