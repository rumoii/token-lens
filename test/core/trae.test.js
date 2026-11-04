import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseTrae } from '../../src/core/adapters/trae.js';

test('parseTrae should parse JSON file with sessions array and deduct cached tokens', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-trae-'));
  const filePath = join(tmp, 'trae-export.json');

  const mockPayload = {
    sessions: [
      {
        session_id: 'trae-s1',
        model_name: 'doubao-pro',
        usage_time: 1784357000,
        input_token: 500,
        output_token: 70,
        cache_read_token: 200,
        cache_write_token: 50
      },
      {
        session_id: 'trae-s2',
        model_name: 'doubao-lite',
        usage_time: '2026-10-15T10:00:00.000Z',
        extra_info: {
          input_token: 1000,
          output_token: 250,
          cache_read_token: 0
        }
      }
    ]
  };

  writeFileSync(filePath, JSON.stringify(mockPayload, null, 2), 'utf8');

  const records = [];
  for await (const r of parseTrae(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 2);

  // 第一条：500 input - 200 cacheRead = 300 uncached input
  assert.equal(records[0].source, 'trae');
  assert.equal(records[0].session_id, 'trae-s1');
  assert.equal(records[0].model, 'doubao-pro');
  assert.equal(records[0].input_tokens, 300);
  assert.equal(records[0].output_tokens, 70);
  assert.equal(records[0].cache_read_tokens, 200);
  assert.equal(records[0].cache_creation_tokens, 50);

  // 第二条：从 extra_info 提取
  assert.equal(records[1].session_id, 'trae-s2');
  assert.equal(records[1].model, 'doubao-lite');
  assert.equal(records[1].input_tokens, 1000);
  assert.equal(records[1].output_tokens, 250);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseTrae should stream JSONL format correctly', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-trae-'));
  const filePath = join(tmp, 'trae-stream.jsonl');

  const lines = [
    JSON.stringify({
      id: 'stream-s1',
      model: 'doubao-pro',
      timestamp: '2026-10-15T12:00:00.000Z',
      inputTokens: 800,
      outputTokens: 120,
      cachedTokens: 300
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseTrae(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'trae');
  assert.equal(records[0].session_id, 'stream-s1');
  assert.equal(records[0].model, 'doubao-pro');
  assert.equal(records[0].input_tokens, 500); // 800 - 300
  assert.equal(records[0].output_tokens, 120);
  assert.equal(records[0].cache_read_tokens, 300);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseTrae should ignore empty or non-existent files gracefully', async () => {
  const empty = [];
  for await (const r of parseTrae('non-existent-trae.json')) {
    empty.push(r);
  }
  assert.equal(empty.length, 0);
});

test('C4 trae JSON: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-trae-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.json'), JSON.stringify({
      session_id: 's',
      timestamp: '2026-10-26T08:30:00.000Z',
      input_token: 10,
      output_token: 2
    }));
    const records = [];
    for await (const record of parseTrae(join(tmp, 'session-nomodel.json'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 trae JSONL: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-trae-nomodel-'));
  try {
    writeFileSync(join(tmp, 'session-nomodel.jsonl'), JSON.stringify({
      session_id: 's',
      timestamp: '2026-10-26T08:30:00.000Z',
      input_token: 10,
      output_token: 2
    }));
    const records = [];
    for await (const record of parseTrae(join(tmp, 'session-nomodel.jsonl'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
