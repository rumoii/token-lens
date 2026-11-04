import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { buildSessionDetail } from '../../src/core/api/v1/sessions.js';

/**
 * @param {Object[]} records
 * @returns {Ledger}
 */
function seed(records) {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch(records, { priceOf: costOf });
  return ledger;
}

const CLAUDE_SESSION = [
  { source: 'claude', record_key: 'a1', session_id: 's1', project_key: 'D:/x',
    model: 'claude-opus-5-5', observed_at: '2026-10-19T10:05:00.000Z', kind: 'event',
    input_tokens: 10, output_tokens: 20, cache_read_tokens: 5, cache_write_tokens: 0 },
  { source: 'claude', record_key: 'a2', session_id: 's1', project_key: 'D:/x',
    model: 'claude-opus-5-5', observed_at: '2026-10-19T10:35:00.000Z', kind: 'event',
    input_tokens: 1, output_tokens: 2, cache_read_tokens: 3, cache_write_tokens: 0 },
  { source: 'claude', record_key: 'a3', session_id: 's1', project_key: 'D:/x',
    model: 'claude-sonnet-5-5', observed_at: '2026-10-19T11:05:00.000Z', kind: 'event',
    input_tokens: 4, output_tokens: 5, cache_read_tokens: 6, cache_write_tokens: 0 }
];

test('会话详情：汇总、模型构成与时间线', () => {
  const ledger = seed(CLAUDE_SESSION);

  const detail = ledger.read.sessionDetail({ source: 'claude', sessionId: 's1' });
  assert.ok(detail);
  assert.equal(detail.summary.record_count, 3);
  assert.equal(detail.summary.gross_tokens, 56, '10+20+5 + 1+2+3 + 4+5+6');
  assert.equal(detail.summary.started_at, '2026-10-19T10:05:00.000Z');
  assert.equal(detail.summary.last_seen_at, '2026-10-19T11:05:00.000Z');
  assert.equal(detail.summary.project_key, 'D:/x');

  assert.equal(detail.models.length, 2);
  const opus = detail.models.find((m) => m.model === 'claude-opus-5-5');
  assert.equal(opus.record_count, 2);
  assert.equal(opus.gross_tokens, 41);

  assert.equal(detail.timeline.length, 2, '两条落在 10 点桶，一条在 11 点桶');
  assert.equal(detail.timeline[0].bucket, '2026-10-19T10:00:00');
  assert.equal(detail.kinds.event, 3);
  assert.equal(detail.kinds.cumulative, 0);

  ledger.close();
});

test('会话身份是 source 与 session_id 的组合', () => {
  const ledger = seed([
    ...CLAUDE_SESSION,
    { source: 'codex', record_key: 'b1', session_id: 's1', project_key: 'D:/y',
      model: 'gpt-6.1-sol', observed_at: '2026-10-19T10:00:00.000Z', kind: 'event',
      input_tokens: 7, output_tokens: 8, cache_read_tokens: 0, cache_write_tokens: null }
  ]);

  const codex = ledger.read.sessionDetail({ source: 'codex', sessionId: 's1' });
  assert.equal(codex.summary.record_count, 1, '不会被同名的 claude 会话污染');
  assert.equal(codex.summary.gross_tokens, 15);

  const claude = ledger.read.sessionDetail({ source: 'claude', sessionId: 's1' });
  assert.equal(claude.summary.record_count, 3);

  ledger.close();
});

test('不存在的会话返回 null', () => {
  const ledger = seed(CLAUDE_SESSION);
  assert.equal(ledger.read.sessionDetail({ source: 'claude', sessionId: 'nope' }), null);
  assert.equal(ledger.read.sessionDetail({ source: 'nope', sessionId: 's1' }), null);
  ledger.close();
});

test('缺 source 或 session_id 直接报错', () => {
  const ledger = seed(CLAUDE_SESSION);
  assert.throws(() => ledger.read.sessionDetail({ sessionId: 's1' }), /必须同时给出/);
  assert.throws(() => ledger.read.sessionDetail({ source: 'claude' }), /必须同时给出/);
  ledger.close();
});

test('会话跨多个项目时项目归属返回 null', () => {
  const ledger = seed([
    ...CLAUDE_SESSION,
    { source: 'claude', record_key: 'a4', session_id: 's1', project_key: 'D:/other',
      model: 'claude-opus-5-5', observed_at: '2026-10-19T12:05:00.000Z', kind: 'event',
      input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0 }
  ]);

  const detail = ledger.read.sessionDetail({ source: 'claude', sessionId: 's1' });
  assert.equal(detail.summary.project_key, null, '不替用户挑一个项目');
  ledger.close();
});

test('累计型会话没有时间线，但汇总照算', () => {
  const ledger = seed([
    { source: 'dsh', record_key: 'c1', session_id: 'd1', project_key: null,
      model: 'deepseek-flash', observed_at: '2026-10-19T09:00:00.000Z', kind: 'cumulative',
      input_tokens: 100, output_tokens: 50, cache_read_tokens: 25, cache_write_tokens: 0 }
  ]);

  const detail = ledger.read.sessionDetail({ source: 'dsh', sessionId: 'd1' });
  assert.equal(detail.summary.gross_tokens, 175);
  assert.equal(detail.kinds.cumulative, 1);
  assert.equal(detail.kinds.event, 0);
  assert.equal(detail.timeline.length, 0, '累计快照不进时间线，与全局口径一致');
  ledger.close();
});

test('API 层：缺参返回 invalid_param，不存在返回 notFound', () => {
  const ledger = seed(CLAUDE_SESSION);

  const missing = buildSessionDetail(ledger.read, { source: 'claude' });
  assert.equal(missing.error.code, 'invalid_param');

  const blank = buildSessionDetail(ledger.read, { source: '  ', session_id: '  ' });
  assert.equal(blank.error.code, 'invalid_param');

  const notFound = buildSessionDetail(ledger.read, { source: 'claude', session_id: 'nope' });
  assert.equal(notFound.notFound, true);

  const ok = buildSessionDetail(ledger.read, { source: 'claude', session_id: 's1' });
  assert.equal(ok.session.session_id, 's1');
  assert.equal(ok.session.record_count, 3);
  assert.equal(ok.models.length, 2);
  assert.ok(ok.models.every((m) => m.price_state), '每个模型带价格状态');
  assert.equal(ok.timeline.length, 2);
  assert.ok(ok.snapshot);

  ledger.close();
});
