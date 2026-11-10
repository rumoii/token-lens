import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { compare } from './compare-real.mjs';

function sample() {
  return [
    { type: 'context', format: 1, now: '2026-01-15T12:00:00.000Z', tz: 'UTC', home: '/synthetic' },
    ...['a', 'b'].map(record_key => ({ type: 'ledger_row', table: 'usage_records', expected: {
      record_key, source: 'claude', input_tokens: 10, output_tokens: null,
      cache_read_tokens: 0, cache_write_tokens: 0, cost_micros: null, ingested_at: 1,
    } })),
    { type: 'ledger_row', table: 'pricing_snapshot', expected: { version: 'p', created_at: 1, verified_at: '2026-01-15' } },
    { type: 'ledger_row', table: 'legacy_records', expected: { id: 1, imported_at: 1 } },
    ...[0, 1].map(index => ({ type: 'run', index, expected: {
      inserted: index === 0 ? 2 : 0, updated: 0, fileCount: 1, anomalies: 0,
      counts: { bad_fields: 0, bad_times: 0 }, durationMs: 1,
    } })),
    { type: 'source_notes', source: 'claude', expected: { bad_fields: 0, bad_times: 0 } },
    { type: 'query', fn: 'summary', range: 'all', expected: { totals: { gross_tokens: 20 } } },
  ];
}

test('identical exports match and preserve unknown totals', () => {
  const result = compare(sample(), sample());
  assert.equal(result.diffs.length, 0);
  assert.equal(result.overview[0].old.cost_micros, null);
});
test('field mutation, removed row, run anomaly and query mutation are all found', () => {
  const right = sample();
  right[1].expected.input_tokens = 11;
  right.splice(2, 1);
  right.find(row => row.type === 'run').expected.counts.bad_fields++;
  right.find(row => row.type === 'run').expected.anomalies++;
  right.find(row => row.type === 'query').expected.totals.gross_tokens++;
  const { diffs } = compare(sample(), right);
  for (const field of ['input_tokens', '$row', 'counts.bad_fields', 'anomalies', 'totals.gross_tokens']) {
    assert.ok(diffs.some(diff => diff.field === field), field);
  }
});
test('only the four scoped volatile fields are excluded', () => {
  const right = sample();
  right[1].expected.ingested_at++;
  right.find(row => row.table === 'pricing_snapshot').expected.created_at++;
  right.find(row => row.table === 'legacy_records').expected.imported_at++;
  right.find(row => row.type === 'run').expected.durationMs++;
  assert.equal(compare(sample(), right).diffs.length, 0);
  right.find(row => row.table === 'pricing_snapshot').expected.verified_at = '2026-01-16';
  assert.ok(compare(sample(), right).diffs.some(diff => diff.field === 'verified_at'));
  right.find(row => row.type === 'query').expected.ingested_at = 9;
  assert.ok(compare(sample(), right).diffs.some(diff => diff.field === 'ingested_at'));
});
test('each side is independently checked for second-sync changes', () => {
  const left = sample();
  const right = sample();
  for (const side of [left, right]) side.find(row => row.type === 'run' && row.index === 1).expected.updated = 1;
  const { diffs } = compare(left, right);
  for (const side of ['old', 'new']) assert.ok(diffs.some(diff => diff.kind === 'idempotence' && diff.side === side));
});
test('duplicate identities and absent run coverage fail closed', () => {
  assert.throws(() => compare([...sample(), sample()[1]], sample()), /duplicate/);
  assert.throws(() => compare(sample().filter(row => row.type !== 'run'), sample()), /two runs/);
});
test('unordered query lists compare by identity and still compare every value', () => {
  const left = sample(), right = sample();
  for (const side of [left, right]) side.push({ type: 'query', fn: 'sessions', range: 'all', expected: { items: [
    { source: 'claude', session_id: 'a', gross_tokens: 1 },
    { source: 'codex', session_id: 'b', gross_tokens: 2 },
  ] } });
  right.at(-1).expected.items.reverse();
  assert.equal(compare(left, right).diffs.length, 0);
  right.at(-1).expected.items[0].gross_tokens++;
  assert.ok(compare(left, right).diffs.some(diff => diff.field === 'items.1.gross_tokens'));
});
test('matching counter values do not hide identical mutations on both sides', () => {
  const left = sample(), right = sample();
  for (const side of [left, right]) side.push({ type: 'query', fn: 'usage_digest', range: 'idempotence', expected: { before: 'a', after: 'b' } });
  assert.equal(compare(left, right).diffs.filter(diff => diff.kind === 'idempotence').length, 2);
});
test('a full export cannot silently omit a query or a source audit', () => {
  const rows = sample();
  Object.assign(rows[0], { complete: true, sources: ['claude'] });
  assert.throws(() => compare(rows, rows), /coverage/);
});
test('CLI reads mutations from disk, writes all diffs and returns failure', () => {
  const root = mkdtempSync(join(tmpdir(), 'token-lens-d35a-compare-'));
  const left = sample(), right = sample();
  right[1].expected.input_tokens++;
  right.splice(2, 1);
  right.find(row => row.type === 'run').expected.anomalies++;
  const save = (name, rows) => writeFileSync(join(root, name), rows.map(row => JSON.stringify(row)).join('\n') + '\n');
  save('old.jsonl', left); save('new.jsonl', right);
  const invoke = () => spawnSync(process.execPath, [fileURLToPath(new URL('./compare-real.mjs', import.meta.url)), join(root, 'old.jsonl'), join(root, 'new.jsonl'), root], { encoding: 'utf8' });
  assert.equal(invoke().status, 1);
  const diff = readFileSync(join(root, 'diff.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line));
  for (const field of ['input_tokens', '$row', 'anomalies']) assert.ok(diff.some(row => row.field === field));
  const volatileOnly = sample(); volatileOnly[1].expected.ingested_at++;
  save('new.jsonl', volatileOnly);
  assert.equal(invoke().status, 0);
  assert.equal(readFileSync(join(root, 'diff.jsonl'), 'utf8'), '');
  assert.match(readFileSync(join(root, 'report.md'), 'utf8'), /无差异/);
});
test('diff output keeps numeric evidence and hashes non-ledger text', () => {
  const left = sample(), right = sample();
  right[1].expected.input_tokens++;
  left.at(-1).expected.text = 'D35_PRIVATE_A'; right.at(-1).expected.text = 'D35_PRIVATE_B';
  const result = compare(left, right);
  const numeric = result.diffs.find(diff => diff.field === 'input_tokens');
  assert.deepEqual([numeric.old_value, numeric.new_value], [10, 11]);
  assert.ok(!JSON.stringify(result).includes('D35_PRIVATE'));
  assert.match(result.diffs.find(diff => diff.field === 'text').old_value.sha256, /^[0-9a-f]{64}$/);
});
