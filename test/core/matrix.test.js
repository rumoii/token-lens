import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { buildSummary, buildMatrix, buildBreakdown } from '../../src/core/api/v1/usage.js';

/**
 * 造一个可手算的小库：一个模型、两天、两来源、一个项目。
 * claude-opus-5-5 的价格是 4 / 20 / 0.2 / 5（USD / 1M）。
 */
function seed(ledger) {
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'a1', session_id: 's1', project_key: 'proj-a',
      model: 'claude-opus-5-5', observed_at: '2026-10-01T10:00:00.000Z', kind: 'event',
      input_tokens: 1_000_000, output_tokens: 1_000_000,
      cache_read_tokens: 1_000_000, cache_write_tokens: 1_000_000 },
    { source: 'claude', record_key: 'a2', session_id: 's1', project_key: 'proj-a',
      model: 'claude-opus-5-5', observed_at: '2026-10-02T10:00:00.000Z', kind: 'event',
      input_tokens: 500_000, output_tokens: 0,
      cache_read_tokens: 0, cache_write_tokens: 0 },
    { source: 'codex', record_key: 'b1', session_id: 's2', project_key: 'proj-b',
      model: 'gpt-6.1-sol', observed_at: '2026-10-02T12:00:00.000Z', kind: 'event',
      input_tokens: 1_000_000, output_tokens: 1_000_000,
      cache_read_tokens: 0, cache_write_tokens: null },
    // 累计型：没有时间分布，只能进 unallocated
    { source: 'dsh', record_key: 'c1', session_id: 's3', project_key: null,
      model: 'claude-opus-5-5', observed_at: '2026-10-02T09:00:00.000Z', kind: 'cumulative',
      input_tokens: 200_000, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 }
  ], { priceOf: costOf });
}

const micros = (usd) => Math.round(Number(usd) * 1e6);

test('矩阵：行之和 + 未分配 == 总额', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const totals = buildSummary(ledger.read, {}).totals;
  const matrix = buildMatrix(ledger.read, { granularity: 'day', by: 'model' });

  const rowsGross = matrix.rows.reduce((sum, r) => sum + r.gross_tokens, 0);
  const rowsCost = matrix.rows.reduce((sum, r) => sum + micros(r.cost_usd || 0), 0);
  const unallocGross = matrix.unallocated?.gross_tokens ?? 0;
  const unallocCost = micros(matrix.unallocated?.cost_usd || 0);

  assert.equal(rowsGross + unallocGross, totals.gross_tokens, 'token 合计必须对齐');
  assert.equal(rowsCost + unallocCost, micros(totals.cost_usd), '金额合计必须对齐');
  assert.ok(matrix.unallocated, '累计型必须单独出现，不能被丢掉');
  ledger.close();
});

test('矩阵：粒度与维度都生效', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const byDay = buildMatrix(ledger.read, { granularity: 'day', by: 'model' }).rows;
  const byMonth = buildMatrix(ledger.read, { granularity: 'month', by: 'model' }).rows;
  const byProject = buildMatrix(ledger.read, { granularity: 'day', by: 'project' }).rows;

  assert.equal(new Set(byDay.map((r) => r.bucket)).size, 2, '两天');
  assert.equal(new Set(byMonth.map((r) => r.bucket)).size, 1, '同一个月');
  assert.deepEqual(
    [...new Set(byProject.map((r) => r.key))].sort(),
    ['proj-a', 'proj-b'],
    '项目维度要出真实分组'
  );

  // 同一批数据换粒度，总额不变
  const sum = (rows) => rows.reduce((s, r) => s + r.gross_tokens, 0);
  assert.equal(sum(byDay), sum(byMonth));
  ledger.close();
});

test('成本拆分：四类之和严格等于该组金额', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  for (const by of ['model', 'source', 'project']) {
    const { groups } = buildBreakdown(ledger.read, { by });
    for (const group of groups) {
      assert.ok(group.cost_by_kind, `${by}/${group.key} 必须有成本拆分`);
      const sum = Object.values(group.cost_by_kind).reduce((s, v) => s + micros(v), 0);
      assert.equal(sum, micros(group.cost_usd), `${by}/${group.key} 拆分之和必须等于金额`);
    }
  }
  ledger.close();
});

test('成本拆分：按各模型单价算，不是平均价', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const { groups } = buildBreakdown(ledger.read, { by: 'model' });
  const opus = groups.find((g) => g.key === 'claude-opus-5-5');
  const kinds = opus.cost_by_kind;

  // opus 组含三条记录：1M + 0.5M 事件型，加 0.2M 累计型
  // 输入 1.7M × $4 = $6.8；输出 1M × $20 = $20；命中 1M × $0.2 = $0.2；写入 1M × $5 = $5
  assert.equal(micros(kinds.input), 6_800_000);
  assert.equal(micros(kinds.output), 20_000_000);
  assert.equal(micros(kinds.cache_read), 200_000);
  assert.equal(micros(kinds.cache_write), 5_000_000);
  ledger.close();
});

test('头部活跃度：会话数、事件条数、缓存命中率、跨度', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const { activity } = buildSummary(ledger.read, {});
  assert.equal(activity.sessions, 3, '三个会话');
  assert.equal(activity.turns, 3, '累计型不计入轮次');
  // 输入 2.7M（opus 1.7M + gpt 1M），缓存命中 1M → 1 / (2.7 + 1)
  assert.equal(activity.cache_hit_ratio, 0.2703);
  assert.equal(activity.first_seen, '2026-10-01T10:00:00.000Z');
  assert.equal(activity.last_seen, '2026-10-02T12:00:00.000Z');
  assert.equal(activity.active_span_ms, 26 * 3600 * 1000, '10-01 10:00 到 10-02 12:00');
  ledger.close();
});

test('空库：活跃度给 0 与 null，不编数字', () => {
  const ledger = new Ledger(':memory:');
  const { activity, totals } = buildSummary(ledger.read, {});

  assert.equal(totals.record_count, 0);
  assert.equal(activity.sessions, 0);
  assert.equal(activity.turns, 0);
  assert.equal(activity.cache_hit_ratio, null, '没有 token 时不给比值');
  assert.equal(activity.active_span_ms, null);
  ledger.close();
});

test('工具 × 模型：每组带 source 与 model，分组之和等于总额', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const { by, groups, totals } = buildBreakdown(ledger.read, { by: 'source_model' });
  assert.equal(by, 'source_model');
  const pairs = groups.map((g) => `${g.source}/${g.model}`).sort();
  assert.deepEqual(pairs, ['claude/claude-opus-5-5', 'codex/gpt-6.1-sol', 'dsh/claude-opus-5-5']);
  assert.ok(groups.every((g) => g.key === g.model));

  assert.equal(groups.reduce((s, g) => s + g.gross_tokens, 0), totals.gross_tokens);
  assert.equal(groups.reduce((s, g) => s + micros(g.cost_usd || 0), 0), micros(totals.cost_usd));
  for (const g of groups) {
    const sum = Object.values(g.cost_by_kind).reduce((s, v) => s + micros(v), 0);
    assert.equal(sum, micros(g.cost_usd), `${g.source}/${g.model} 拆分之和必须等于金额`);
  }

  const onlyClaude = buildBreakdown(ledger.read, { by: 'source_model', source: 'claude' }).groups;
  assert.deepEqual(onlyClaude.map((g) => g.source), ['claude'], '筛选照常生效');
  ledger.close();
});
