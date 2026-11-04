import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { buildSources } from '../../src/core/api/v1/sources.js';
import { buildPricing } from '../../src/core/api/v1/pricing.js';

/** 与 `src/core/adapters/index.js` 注册的 27 组一致。 */
const ALL_SOURCES = [
  'claude', 'codex', 'qwen', 'dsh', 'grok', 'aider', 'pi', 'hermes', 'cline', 'gemini', 'cursor',
  'opencode', 'kilo', 'openhands', 'goose', 'zed', 'continue', 'trae', 'copilot', 'openclaw', 'mimo', 'kimi',
  'minimax', 'codebuddy', 'zcode', 'commandcode', 'anythingllm'
];

/**
 * @param {string[]} sources
 * @param {string} [model]
 * @returns {Ledger}
 */
function seed(sources, model = 'claude-opus-5-5') {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch(
    sources.map((source) => ({
      source,
      record_key: `${source}|s|1`,
      session_id: 's',
      model,
      observed_at: '2026-10-19T00:00:00.000Z',
      kind: 'event',
      input_tokens: 1000,
      output_tokens: 500,
      cache_read_tokens: 2000,
      cache_write_tokens: 100
    })),
    { priceOf: costOf }
  );
  return ledger;
}

test('27 组来源都带口径限制，没有一组是空白', () => {
  assert.equal(ALL_SOURCES.length, 27, '名单应覆盖全部 27 组来源');
  const ledger = seed(ALL_SOURCES);
  const { sources } = buildSources(ledger.read);
  assert.equal(sources.length, ALL_SOURCES.length, '每组都要出现');

  for (const item of sources) {
    assert.ok(
      Array.isArray(item.limits) && item.limits.length > 0,
      `${item.source} 应当有至少一条已知限制`
    );
    assert.ok(
      item.limits.every((limit) => typeof limit === 'string' && limit.length > 0),
      `${item.source} 的限制不能是空串`
    );
  }
  ledger.close();
});

test('证据等级：只有用真实日志对照过的六组是 A', () => {
  const ledger = seed(ALL_SOURCES);
  const { sources } = buildSources(ledger.read);
  const bySource = new Map(sources.map((item) => [item.source, item]));

  const verified = ['claude', 'codex', 'qwen', 'pi', 'dsh', 'kimi'];
  for (const source of verified) {
    assert.equal(bySource.get(source).evidence, 'A', `${source} 应当为 A`);
  }
  for (const source of ALL_SOURCES.filter((s) => !verified.includes(s))) {
    assert.equal(bySource.get(source).evidence, 'B', `${source} 应当为 B`);
  }
  ledger.close();
});

test('L5 来源说明按会话选择 Copilot，用内容身份识别 OpenClaw 副本', () => {
  const ledger = seed(['copilot', 'openclaw']);
  try {
    const sources = new Map(buildSources(ledger.read).sources.map(item => [item.source, item]));
    assert.ok(sources.get('copilot').limits.some(text => text.includes('同一会话优先明细')));
    assert.ok(sources.get('openclaw').limits.some(text => text.includes('内容身份相同')));
  } finally { ledger.close(); }
});

test('价格页返回五项单价，单位是 USD / 百万 token', () => {
  const ledger = seed(['claude']);
  const { models } = buildPricing(ledger.read);
  const opus = models.find((m) => m.model === 'claude-opus-5-5');

  assert.ok(opus, '模型应当出现在价格页');
  assert.deepEqual(opus.prices, {
    input: 4,
    output: 20,
    cache_read: 0.2,
    cache_write_5m: 5,
    cache_write_1h: 8
  });
  ledger.close();
});

test('未定价模型的 prices 为 null，不是全 0', () => {
  const ledger = seed(['claude'], 'qwen:uncensored-4b');
  const { models, counts } = buildPricing(ledger.read);
  const unknown = models.find((m) => m.model === 'qwen:uncensored-4b');

  assert.equal(unknown.state, 'unknown');
  assert.equal(unknown.prices, null);
  assert.equal(counts.unknown, 1);
  ledger.close();
});

test('某分项不单独计价时为 null 而不是 0', () => {
  // gpt-5.3-codex 在目录里没有缓存写费率
  const ledger = seed(['codex'], 'gpt-5.3-codex');
  const { models } = buildPricing(ledger.read);
  const model = models.find((m) => m.model === 'gpt-5.3-codex');

  assert.equal(model.prices.cache_write_5m, null, '没有费率就是未知');
  assert.equal(model.prices.cache_write_1h, null);
  assert.equal(typeof model.prices.input, 'number');
  ledger.close();
});

test('每条口径限制都配一句给使用者看的说明，并标明影响', () => {
  const ledger = seed(ALL_SOURCES);
  const { sources } = buildSources(ledger.read);
  for (const item of sources) {
    assert.equal(item.notes.length, item.limits.length, `${item.source} 的说明要和原文一一对应`);
    for (const note of item.notes) {
      assert.ok(typeof note.text === 'string' && note.text.length > 0, `${item.source} 的说明不能是空串`);
      assert.ok(['affects', 'handled'].includes(note.impact), `${item.source} 的影响只能是 affects 或 handled`);
    }
  }
  ledger.close();
});

test('record_mode 按账本里的记录类型给出，first_observed_at 取最早一条', () => {
  const ledger = new Ledger(':memory:');
  const row = (source, key, kind, observed_at) => ({
    source, record_key: key, session_id: key, model: 'claude-opus-5-5', observed_at, kind,
    input_tokens: 10, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0
  });
  ledger.write.ingestBatch([
    row('codex', 'c1', 'event', '2026-10-18T08:00:00.000Z'),
    row('codex', 'c2', 'event', '2026-10-17T08:00:00.000Z'),
    row('dsh', 'd1', 'cumulative', '2026-10-19T08:00:00.000Z'),
    row('cline', 'l1', 'event', '2026-10-19T08:00:00.000Z'),
    row('cline', 'l2', 'cumulative', '2026-10-19T09:00:00.000Z')
  ], { priceOf: costOf });
  const bySource = new Map(buildSources(ledger.read).sources.map((item) => [item.source, item]));
  assert.equal(bySource.get('codex').record_mode, 'event');
  assert.equal(bySource.get('dsh').record_mode, 'cumulative');
  assert.equal(bySource.get('cline').record_mode, 'mixed');
  assert.equal(bySource.get('codex').first_observed_at, '2026-10-17T08:00:00.000Z');
  ledger.close();
});

test('L6 自检：时间越界、单条请求过大、缺模型、同会话混用两种记录方式按来源计数', () => {
  const ledger = new Ledger(':memory:');
  const row = (key, fields) => ({
    source: 'qwen', record_key: key, session_id: key, model: 'claude-opus-5-5',
    observed_at: '2026-10-19T08:00:00.000Z', kind: 'event',
    input_tokens: 10, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0, ...fields
  });
  ledger.write.ingestBatch([
    row('ok', {}),
    row('future', { observed_at: '2026-10-21T00:00:00.000Z' }),
    row('early', { observed_at: '2022-12-31T23:59:59.000Z' }),
    row('huge', { cache_read_tokens: 100_000_000 }),
    row('huge-snapshot', { kind: 'cumulative', cache_read_tokens: 300_000_000 }),
    row('nomodel', { model: null }),
    row('m1', { session_id: 'mixed', kind: 'event' }),
    row('m2', { session_id: 'mixed', kind: 'cumulative' })
  ], { priceOf: costOf });

  const { sources } = buildSources(ledger.read, { now: new Date('2026-10-20T00:00:00.000Z'), exists: () => false });
  assert.deepEqual(sources.find((item) => item.source === 'qwen').checks, {
    time_out_of_range: 2,
    // 累计快照是整场会话的总数，超过 1 亿是正常的，只查逐条请求
    huge_requests: 1,
    null_model: 1,
    mixed_kind_sessions: 1
  });
  ledger.close();
});

test('L6 留存：日志文件仍在的记录可复核，文件已删或没有出处的照常计入但不可复核', () => {
  const ledger = new Ledger(':memory:');
  const row = (key) => ({
    source: 'pi', record_key: key, session_id: 's', model: 'claude-opus-5-5',
    observed_at: '2026-10-19T08:00:00.000Z', kind: 'event',
    input_tokens: 10, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0
  });
  ledger.write.ingestBatch([row('a1'), row('a2')], { priceOf: costOf, sourceFile: '/logs/kept.jsonl' });
  ledger.write.ingestBatch([row('b1')], { priceOf: costOf, sourceFile: '/logs/gone.jsonl' });
  ledger.write.ingestBatch([row('c1')], { priceOf: costOf });

  const seen = [];
  const exists = (path) => { seen.push(path); return path === '/logs/kept.jsonl'; };
  const pi = buildSources(ledger.read, { exists }).sources.find((item) => item.source === 'pi');
  assert.deepEqual(pi.retention, { reviewable: 2, logs_gone: 2 });
  assert.equal(pi.records, 4);
  assert.deepEqual(seen.sort(), ['/logs/gone.jsonl', '/logs/kept.jsonl'], '每个文件只查一次，没有出处的不查');
  ledger.close();
});
