import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { projectFromCwd, firstProject } from '../../src/core/adapters/_project.js';

test('项目键：Windows 路径统一分隔符并去尾部斜杠', () => {
  assert.equal(projectFromCwd('D:\\work\\app'), 'D:\\work\\app');
  assert.equal(projectFromCwd('D:/work/app/'), 'D:\\work\\app');
  assert.equal(projectFromCwd('  C:\\proj  '), 'C:\\proj');
});

test('项目键：POSIX 路径保留，根目录不塌成空串', () => {
  assert.equal(projectFromCwd('/home/alice/src/app'), '/home/alice/src/app');
  assert.equal(projectFromCwd('/home/alice/src/app///'), '/home/alice/src/app');
  assert.equal(projectFromCwd('/'), '/');
});

test('项目键：空值与异常输入给 null，不编一个路径', () => {
  assert.equal(projectFromCwd(null), null);
  assert.equal(projectFromCwd(undefined), null);
  assert.equal(projectFromCwd(''), null);
  assert.equal(projectFromCwd('   '), null);
  assert.equal(projectFromCwd(42), null);
  assert.equal(firstProject(null, '', 'D:\\a'), 'D:\\a');
  assert.equal(firstProject(null, undefined), null);
});

function seed(ledger, project) {
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'k1', session_id: 's1', project_key: project,
      model: 'claude-opus-5-5', observed_at: '2026-10-10T00:00:00.000Z', kind: 'event',
      input_tokens: 1000, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0 }
  ], { priceOf: costOf });
}

test('内容不变但项目被识别出来时，只补归属，不动用量与金额', () => {
  const ledger = new Ledger(':memory:');
  const record = {
    source: 'claude', record_key: 'k1', session_id: 's1', project_key: null,
    model: 'claude-opus-5-5', observed_at: '2026-10-10T00:00:00.000Z', kind: 'event',
    input_tokens: 1000, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0
  };

  ledger.write.ingestBatch([record], { priceOf: costOf });
  const before = ledger.read.totals();

  const again = ledger.write.ingestBatch([{ ...record, project_key: 'D:\\work\\app' }], { priceOf: costOf });
  const after = ledger.read.totals();

  assert.equal(again.counts.relabeled, 1, '应记为重新归属而不是未变');
  assert.equal(again.unchanged, 0);
  assert.equal(after.gross_tokens, before.gross_tokens);
  assert.equal(after.cost_micros, before.cost_micros);

  const projects = ledger.read.breakdown('project');
  assert.equal(projects.length, 1);
  assert.equal(projects[0].bucket, 'D:\\work\\app');
  ledger.close();
});

test('项目已正确时重复采集不改任何行', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger, 'D:\\a');
  const stats = ledger.write.ingestBatch([
    { source: 'claude', record_key: 'k1', session_id: 's1', project_key: 'D:\\a',
      model: 'claude-opus-5-5', observed_at: '2026-10-10T00:00:00.000Z', kind: 'event',
      input_tokens: 1000, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0 }
  ], { priceOf: costOf });

  assert.equal(stats.counts.relabeled, 0);
  assert.equal(stats.unchanged, 1);
  ledger.close();
});

test('会话列表可按项目过滤', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'a', session_id: 's1', project_key: 'D:\\a',
      model: 'claude-opus-5-5', observed_at: '2026-10-10T00:00:00.000Z', kind: 'event',
      input_tokens: 10, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0 },
    { source: 'claude', record_key: 'b', session_id: 's2', project_key: 'D:\\b',
      model: 'claude-opus-5-5', observed_at: '2026-10-11T00:00:00.000Z', kind: 'event',
      input_tokens: 20, output_tokens: 2, cache_read_tokens: 0, cache_write_tokens: 0 }
  ], { priceOf: costOf });

  const filtered = ledger.read.sessions({ filter: { project: 'D:\\b' } });
  assert.equal(filtered.items.length, 1);
  assert.equal(filtered.items[0].session_id, 's2');

  const all = ledger.read.sessions({ filter: {} });
  assert.equal(all.items.length, 2);
  ledger.close();
});
