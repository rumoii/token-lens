import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseGemini } from '../../src/core/adapters/gemini.js';

test('parseGemini should extract top-level usageMetadata from session JSON', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-'));
  const filePath = join(tmp, 'session-abc123.json');

  const session = {
    id: 'gemini-sess-top',
    startTime: '2026-10-16T10:00:00.000Z',
    model: 'gemini-1.5-pro',
    usageMetadata: {
      promptTokenCount: 15000,
      candidatesTokenCount: 3000,
      cachedContentTokenCount: 8000
    }
  };

  writeFileSync(filePath, JSON.stringify(session, null, 2), 'utf8');

  const records = [];
  for await (const r of parseGemini(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'gemini');
  assert.equal(records[0].session_id, 'gemini-sess-top');
  assert.equal(records[0].model, 'gemini-1.5-pro');
  // 15000 prompt - 8000 cached = 7000 uncached input
  assert.equal(records[0].input_tokens, 7000);
  assert.equal(records[0].output_tokens, 3000);
  assert.equal(records[0].cache_read_tokens, 8000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseGemini should extract per-message usageMetadata when top-level is absent', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-'));
  const filePath = join(tmp, 'session-turns.json');

  const session = {
    id: 'gemini-sess-turns',
    startTime: '2026-10-16T11:00:00.000Z',
    messages: [
      { role: 'user', content: 'hello' },
      {
        role: 'model',
        model: 'gemini-1.5-flash',
        createTime: '2026-10-16T11:00:05.000Z',
        usageMetadata: {
          promptTokenCount: 5000,
          candidatesTokenCount: 800,
          cachedContentTokenCount: 0
        }
      }
    ]
  };

  writeFileSync(filePath, JSON.stringify(session, null, 2), 'utf8');

  const records = [];
  for await (const r of parseGemini(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'gemini');
  assert.equal(records[0].model, 'gemini-1.5-flash');
  assert.equal(records[0].input_tokens, 5000);
  assert.equal(records[0].output_tokens, 800);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseGemini should stream JSONL logs correctly', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-'));
  const filePath = join(tmp, 'session-stream.jsonl');

  const lines = [
    JSON.stringify({
      id: 'stream-1',
      timestamp: '2026-10-16T12:00:00.000Z',
      model: 'gemini-2.0-flash',
      usage: {
        input_tokens: 3000,
        output_tokens: 600,
        cache_read_tokens: 500
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseGemini(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'gemini');
  assert.equal(records[0].model, 'gemini-2.0-flash');
  assert.equal(records[0].input_tokens, 2500);
  assert.equal(records[0].output_tokens, 600);
  assert.equal(records[0].cache_read_tokens, 500);

  rmSync(tmp, { recursive: true, force: true });
});

test('C4 gemini JSONL: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.jsonl'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      usage: {
        input_tokens: 10,
        output_tokens: 2
      }
    }));
    const records = [];
    for await (const record of parseGemini(join(tmp, 'session-nomodel.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 gemini JSON-summary: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.json'), JSON.stringify({
      startTime: '2026-10-26T08:30:00.000Z',
      usageMetadata: {
        promptTokenCount: 10,
        candidatesTokenCount: 2
      }
    }));
    const records = [];
    for await (const record of parseGemini(join(tmp, 'session-nomodel.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 gemini JSON-messages: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-gemini-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.json'), JSON.stringify({
      startTime: '2026-10-26T08:30:00.000Z',
      messages: [
        {
          role: 'model',
          usageMetadata: {
            promptTokenCount: 10,
            candidatesTokenCount: 2
          }
        }
      ]
    }));
    const records = [];
    for await (const record of parseGemini(join(tmp, 'session-nomodel.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
