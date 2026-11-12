import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

function displayValue(value, field) {
  if (value === undefined) return { missing: true };
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value;
  const name = field.split('.').at(-1);
  if (typeof value === 'string' && [
    'record_key', 'content_hash', 'source', 'session_id', 'project_key', 'source_file', 'model', 'provider',
    'observed_at', 'ended_at', 'started_at', 'finished_at', 'generated_at', 'price_version', 'price_source',
    'version', 'kind', 'status', 'key', 'bucket', 'from', 'to', 'tz', 'granularity', 'by', 'project', 'cost_usd',
  ].includes(name)) return value;
  return { sha256: createHash('sha256').update(JSON.stringify(value)).digest('hex') };
}

function identity(row) {
  if (row.type === 'context') return 'context';
  if (row.type === 'ledger_row') {
    const key = { usage_records: 'record_key', legacy_records: 'id', pricing_snapshot: 'version', ingest_runs: 'id' }[row.table];
    if (!key || row.expected[key] === undefined) throw Error('invalid ledger identity');
    return JSON.stringify([row.type, row.table, row.expected[key]]);
  }
  if (row.type === 'run') return JSON.stringify(['run', row.index]);
  if (row.type === 'query') return JSON.stringify(['query', row.range, row.fn, row.by ?? null]);
  if (row.type === 'source_notes') return JSON.stringify(['source_notes', row.source]);
  throw Error('invalid export row type');
}

function indexed(rows) {
  const map = new Map();
  for (const row of rows) {
    const key = identity(row);
    if (map.has(key)) throw Error('duplicate export identity');
    map.set(key, row);
  }
  const runs = rows.filter(row => row.type === 'run');
  if (runs.length !== 2 || !runs.some(row => row.index === 0) || !runs.some(row => row.index === 1)) throw Error('expected exactly two runs');
  if (!map.has('context')) throw Error('missing context');
  if (map.get('context').complete) {
    if (rows.filter(row => row.type === 'query' && row.range !== 'idempotence').length !== 32) throw Error('incomplete query coverage');
    for (const range of ['all', 'month', 'week', 'today']) {
      for (const [fn, by] of [['summary'], ['timeseries'], ['matrix'], ['sessions'], ['sources'], ...['source', 'model', 'project'].map(by => ['breakdown', by])]) {
        if (!map.has(JSON.stringify(['query', range, fn, by ?? null]))) throw Error('missing query');
      }
    }
    if (!rows.some(row => row.fn === 'usage_digest')) throw Error('missing idempotence digest');
    for (const source of map.get('context').sources) if (!rows.some(row => row.type === 'source_notes' && row.source === source)) throw Error('missing source notes');
  }
  return map;
}

function ordered(row) {
  const value = structuredClone(row.expected ?? row);
  if (row.type !== 'query') return value;
  const key = { breakdown: 'groups', matrix: 'rows', timeseries: 'points', sessions: 'items', sources: 'sources' }[row.fn];
  if (key && Array.isArray(value[key])) {
    const identity = item => Buffer.from(JSON.stringify(['bucket', 'key', 'source', 'model', 'project_key', 'session_id'].map(field => item[field] ?? null)));
    value[key].sort((a, b) => Buffer.compare(identity(a), identity(b)));
  }
  return value;
}

function volatile(row, field) {
  return (row.type === 'ledger_row' && ({
    usage_records: 'ingested_at', legacy_records: 'imported_at', pricing_snapshot: 'created_at',
  }[row.table] === field)) || (row.type === 'run' && field === 'durationMs');
}

function fields(left, right, path, emit, row) {
  if (volatile(row, path)) return;
  if (left === right) return;
  if (left !== null && right !== null && typeof left === 'object' && typeof right === 'object'
    && Array.isArray(left) === Array.isArray(right)) {
    for (const key of [...new Set([...Object.keys(left), ...Object.keys(right)])].sort()) {
      fields(left[key], right[key], path ? `${path}.${key}` : key, emit, row);
    }
    return;
  }
  emit(path || '$value', left === undefined ? 'new_only' : right === undefined ? 'old_only' : 'changed', left, right);
}

function totals(rows) {
  const sum = key => {
    const known = rows.map(row => row[key]).filter(value => value !== null && value !== undefined);
    return known.length ? known.reduce((a, b) => a + b, 0) : null;
  };
  const result = { rows: rows.length };
  result.unpriced_records = rows.filter(row => row.cost_micros === null).length;
  for (const key of ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens', 'cost_micros']) result[key] = sum(key);
  result.gross_tokens = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'].reduce((n, key) => n + (result[key] ?? 0), 0);
  return result;
}

export function compare(oldRows, newRows) {
  const old = indexed(oldRows), fresh = indexed(newRows), diffs = [];
  const hashes = [old, fresh].map(rows => rows.get('context').seed_sha256);
  if (hashes.some(value => value !== undefined) &&
      (hashes.some(value => typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) || hashes[0] !== hashes[1])) {
    throw Error('seed hash missing, invalid or different');
  }
  for (const key of [...new Set([...old.keys(), ...fresh.keys()])].sort()) {
    const left = old.get(key), right = fresh.get(key), row = left ?? right;
    const base = { kind: row.type, table: row.table ?? null, source: row.source ?? row.expected?.source ?? null,
      record_key: row.table === 'usage_records' ? row.expected.record_key : null,
      fn: row.fn ?? null, by: row.by ?? null, range: row.range ?? null, index: row.index ?? null,
      id: row.expected?.id ?? null, version: row.expected?.version ?? null };
    const emit = (field, change, oldValue, newValue) => diffs.push({ ...base, field, change,
      old_value: displayValue(oldValue, field), new_value: displayValue(newValue, field) });
    if (!left || !right) { emit('$row', left ? 'old_only' : 'new_only'); continue; }
    fields(ordered(left), ordered(right), '', emit, row);
  }
  for (const [side, rows] of [['old', oldRows], ['new', newRows]]) {
    const run = rows.find(row => row.type === 'run' && row.index === 1).expected;
    for (const field of ['inserted', 'updated']) {
      if (!Number.isSafeInteger(run[field]) || run[field] !== 0) diffs.push({ kind: 'idempotence', side, source: null, index: 1, field, change: 'nonzero_or_missing' });
    }
    const digest = rows.find(row => row.fn === 'usage_digest')?.expected;
    if (digest && digest.before !== digest.after) diffs.push({ kind: 'idempotence', side, source: null, index: 1, field: 'usage_records', change: 'changed' });
  }
  const sources = [...new Set([...oldRows, ...newRows].filter(row => row.table === 'usage_records').map(row => row.expected.source))].sort();
  const overview = sources.map(source => {
    const records = rows => rows.filter(row => row.table === 'usage_records' && row.expected.source === source).map(row => row.expected);
    const subset = diffs.filter(diff => diff.table === 'usage_records' && diff.source === source);
    return { source, old: totals(records(oldRows)), new: totals(records(newRows)),
      old_only: subset.filter(diff => diff.change === 'old_only' && diff.field === '$row').length,
      new_only: subset.filter(diff => diff.change === 'new_only' && diff.field === '$row').length,
      changed: new Set(subset.filter(diff => diff.field !== '$row').map(diff => diff.record_key)).size };
  });
  return { diffs, overview };
}

const cell = value => String(value ?? '—').replaceAll('|', '\\|').replaceAll('\n', ' ').replaceAll('\r', ' ');
export function report(result, oldRows, newRows) {
  const rows = ['# D35A parity', '', result.diffs.length ? `差异：${result.diffs.length}` : '无差异', '',
    '| source | old rows | new rows | old tokens | new tokens | old cost_micros | new cost_micros | old unpriced | new unpriced | old only | new only | changed rows |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'];
  for (const row of result.overview) rows.push(`| ${[row.source, row.old.rows, row.new.rows, row.old.gross_tokens, row.new.gross_tokens, row.old.cost_micros, row.new.cost_micros, row.old.unpriced_records, row.new.unpriced_records, row.old_only, row.new_only, row.changed].map(cell).join(' | ')} |`);
  rows.push('', '合计包含全部账本行的已知 token 与金额；NULL 保留为未知，unpriced 列出未定价行数，差异按全部字段比较。', '', '## 来源异常', '', '| source | old bad_fields | new bad_fields | old bad_times | new bad_times |', '|---|---:|---:|---:|---:|');
  const sources = [...new Set([...oldRows, ...newRows].filter(row => row.type === 'source_notes').map(row => row.source))].sort();
  for (const source of sources) {
    const values = [oldRows, newRows].map(list => list.find(row => row.type === 'source_notes' && row.source === source)?.expected);
    rows.push(`| ${[source, values[0]?.bad_fields, values[1]?.bad_fields, values[0]?.bad_times, values[1]?.bad_times].map(cell).join(' | ')} |`);
  }
  rows.push('', '## 差异样例', '', '每个来源、字段、类型最多 20 条；diff.jsonl 保留全部差异。只显示账本标量与计数；其他值用 SHA-256 表示，不输出原始日志正文。');
  const groups = Map.groupBy(result.diffs, diff => JSON.stringify([diff.source, diff.kind, diff.table, diff.field]));
  for (const [group, diffs] of groups) {
    rows.push('', `### ${cell(group)} (${diffs.length})`, '');
    for (const diff of diffs.slice(0, 20)) rows.push(`- ${cell(JSON.stringify(diff))}`);
  }
  return `${rows.join('\n')}\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [oldFile, newFile, output] = process.argv.slice(2);
    if (!oldFile || !newFile || !output || process.argv.length !== 5) throw Error('usage: compare-real.mjs <old.jsonl> <new.jsonl> <report-dir>');
    const read = file => readFileSync(file, 'utf8').trim().split(/\r?\n/).map(line => JSON.parse(line));
    const left = read(oldFile), right = read(newFile), result = compare(left, right);
    mkdirSync(output, { recursive: true });
    writeFileSync(join(output, 'report.md'), report(result, left, right));
    writeFileSync(join(output, 'diff.jsonl'), result.diffs.map(diff => JSON.stringify(diff)).join('\n') + (result.diffs.length ? '\n' : ''));
    console.log(`parity: ${result.diffs.length} differences`);
    process.exitCode = result.diffs.length ? 1 : 0;
  } catch { console.error('parity: invalid or unreadable input; no payload printed'); process.exitCode = 2; }
}
