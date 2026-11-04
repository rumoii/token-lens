import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseClaude } from '../../src/core/adapters/claude.js';
import { parseCodex } from '../../src/core/adapters/codex.js';
import { parseQwen } from '../../src/core/adapters/qwen.js';

test('parseClaude should extract usage records from jsonl and max-merge stream snapshots', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-claude-'));
  const filePath = join(tmp, 'session.jsonl');

  const lines = [
    // 第一次快照：输出为 0，输入已记录
    JSON.stringify({
      sessionId: 'claude-sess-1',
      timestamp: '2026-10-06T12:00:00.000Z',
      message: {
        id: 'msg_001',
        model: 'claude-opus-5-5',
        usage: {
          input_tokens: 150,
          output_tokens: 0,
          cache_read_input_tokens: 20,
          cache_creation_input_tokens: 0
        }
      }
    }),
    // 第二次快照（最终完成态）：输出为 75
    JSON.stringify({
      sessionId: 'claude-sess-1',
      timestamp: '2026-10-06T12:00:05.000Z',
      message: {
        id: 'msg_001',
        model: 'claude-opus-5-5',
        usage: {
          input_tokens: 150,
          output_tokens: 75,
          cache_read_input_tokens: 20,
          cache_creation_input_tokens: 0
        }
      }
    }),
    JSON.stringify({ type: 'progress', data: 'ignored' })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseClaude(filePath)) {
    records.push(r);
  }

  // 必须合并为 1 条，且 output 为最终的 75，绝不计为 2 条
  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'claude');
  assert.equal(records[0].session_id, 'claude-sess-1');
  assert.equal(records[0].input_tokens, 150);
  assert.equal(records[0].output_tokens, 75);
  assert.equal(records[0].cache_read_tokens, 20);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCodex should extract usage records from jsonl', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-codex-'));
  const filePath = join(tmp, 'rollout.jsonl');

  // 形状取自真实 rollout：用量在 payload.usage 下，缓存字段名是 cached_input_tokens，
  // 且 cached 是 input 的子集（见 specs/log-schemas.yaml 的 codex_cli 条目）。
  const lines = [
    JSON.stringify({
      type: 'session_meta',
      payload: { session_id: 'codex-sess-100', model: 'gpt-6.1-sol' }
    }),
    JSON.stringify({
      timestamp: '2026-10-17T11:39:37.000Z',
      type: 'token_usage_record',
      payload: {
        session_id: 'codex-sess-100',
        response_id: 'resp_abc',
        usage: {
          input_tokens: 300,
          cached_input_tokens: 50,
          output_tokens: 120,
          total_tokens: 420
        },
        turn_token_usage: { input_tokens: 999, output_tokens: 999 }
      }
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseCodex(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'codex');
  assert.equal(records[0].session_id, 'codex-sess-100');
  assert.equal(records[0].model, 'gpt-6.1-sol');
  assert.equal(records[0].record_key, 'codex|codex-sess-100|resp_abc');
  assert.equal(records[0].input_tokens, 250, 'input 必须扣掉缓存段');
  assert.equal(records[0].cache_read_tokens, 50);
  assert.equal(records[0].output_tokens, 120);
  assert.equal(
    records[0].input_tokens + records[0].output_tokens + records[0].cache_read_tokens,
    420,
    '口径归一后应等于客户端自报 total_tokens'
  );

  rmSync(tmp, { recursive: true, force: true });
});

test('parseQwen should extract usage records from jsonl', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-qwen-'));
  const filePath = join(tmp, 'token-usage-2026-10.jsonl');

  const lines = [
    JSON.stringify({
      session_id: 'qwen-sess-5',
      timestamp: 1791289349,
      model: 'qwen-coder-plus',
      input_tokens: 500,
      output_tokens: 250,
      cache_read_tokens: 30
    })
  ];

  writeFileSync(filePath, lines.join('\n') + '\n', 'utf8');

  const records = [];
  for await (const r of parseQwen(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'qwen');
  assert.equal(records[0].session_id, 'qwen-sess-5');
  assert.equal(records[0].input_tokens, 500);
  assert.equal(records[0].output_tokens, 250);

  rmSync(tmp, { recursive: true, force: true });
});
