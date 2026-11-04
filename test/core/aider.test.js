import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseAider } from '../../src/core/adapters/aider.js';

test('parseAider should extract OpenAI-style usage from .aider.llm.history', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-aider-'));
  const filePath = join(tmp, '.aider.llm.history');

  const lines = [
    JSON.stringify({
      timestamp: '2026-10-15T08:30:00.000Z',
      model: 'gpt-4o',
      usage: {
        prompt_tokens: 1500,
        completion_tokens: 600,
        prompt_tokens_details: { cached_tokens: 400 }
      }
    }),
    JSON.stringify({
      timestamp: '2026-10-15T08:35:00.000Z',
      response: {
        model: 'deepseek-chat',
        usage: {
          prompt_tokens: 2000,
          completion_tokens: 800
        }
      }
    }),
    '# commentary line that should be skipped',
    ''
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseAider(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 2);

  // 第一条：OpenAI 风格；prompt_tokens 含缓存命中的 400，扣掉后才是纯输入 1100
  assert.equal(records[0].source, 'aider');
  assert.equal(records[0].model, 'gpt-4o');
  assert.equal(records[0].input_tokens, 1100);
  assert.equal(records[0].output_tokens, 600);
  assert.equal(records[0].cache_read_tokens, 400);

  // 第二条：LiteLLM 嵌套 response 风格
  assert.equal(records[1].source, 'aider');
  assert.equal(records[1].model, 'deepseek-chat');
  assert.equal(records[1].input_tokens, 2000);
  assert.equal(records[1].output_tokens, 800);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseAider should extract Anthropic-style usage with cache tokens', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-aider-'));
  const filePath = join(tmp, '.aider.llm.history');

  const lines = [
    JSON.stringify({
      timestamp: 1784357000,
      model: 'claude-3-5-sonnet',
      usage: {
        input_tokens: 3000,
        output_tokens: 1200,
        cache_read_input_tokens: 1500,
        cache_creation_input_tokens: 500
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseAider(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'aider');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 3000);
  assert.equal(records[0].output_tokens, 1200);
  assert.equal(records[0].cache_read_tokens, 1500);
  assert.equal(records[0].cache_creation_tokens, 500);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseAider should not subtract cache_read_input_tokens from Anthropic input', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-aider-'));
  try {
    const filePath = join(tmp, '.aider.llm.history');

    const lines = [
      JSON.stringify({
        timestamp: '2026-10-15T09:00:00.000Z',
        model: 'claude-3-5-sonnet',
        usage: {
          input_tokens: 1000,
          output_tokens: 50,
          cache_read_input_tokens: 800
        }
      })
    ];

    writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

    const records = [];
    for await (const r of parseAider(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    // anthropic 口径的 input_tokens 本来就不含缓存，不扣减
    assert.equal(records[0].input_tokens, 1000);
    assert.equal(records[0].cache_read_tokens, 800);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('C4 aider history: missing model stays NULL', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-aider-nomodel-'));
  try {
    writeFileSync(join(tmp, '.aider.llm.history'), JSON.stringify({
      timestamp: '2026-10-26T08:30:00.000Z',
      usage: {
        prompt_tokens: 10,
        completion_tokens: 2
      }
    }));
    const records = [];
    for await (const record of parseAider(join(tmp, '.aider.llm.history'))) records.push(record);
    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    assert.equal(records[0].input_tokens, 10);
    assert.equal(records[0].output_tokens, 2);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
