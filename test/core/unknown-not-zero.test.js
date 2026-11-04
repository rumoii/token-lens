import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { DatabaseSync } from 'node:sqlite';
import { isEmptyUsage, minus, newNotes, plus, tokenOf } from '../../src/core/adapters/_num.js';
import { jsonLines, normalizeTimestamp } from '../../src/core/adapters/_lines.js';
import { parseClaude } from '../../src/core/adapters/claude.js';
import { parseCodex } from '../../src/core/adapters/codex.js';
import { runIngestion } from '../../src/core/ingest.js';

async function collect(it) {
  const out = [];
  for await (const r of it) out.push(r);
  return out;
}

test('tokenOf：不存在是 null，存在的 0 是 0，非法值记 bad_fields', () => {
  const notes = newNotes();
  assert.equal(tokenOf({}, ['a'], notes), null);
  assert.equal(tokenOf({ a: 0, b: 7 }, ['a', 'b'], notes), 0, '存在的 0 不落到下一个字段');
  assert.equal(tokenOf({ a: null, b: 7 }, ['a', 'b'], notes), 7);
  assert.equal(tokenOf({ a: '12' }, ['a'], notes), 12);
  assert.equal(notes.bad_fields, 0);

  for (const bad of [-1, 1.5, 'abc', '', true, {}, Number.NaN]) {
    assert.equal(tokenOf({ a: bad }, ['a'], notes), null, `非法值 ${String(bad)} 记为未知`);
  }
  assert.equal(notes.bad_fields, 7);
  assert.equal(tokenOf(null, ['a']), null, '不传 notes 时只是不计数');
});

test('minus、plus 与 isEmptyUsage 按未知处理', () => {
  assert.equal(plus(null, null), null);
  assert.equal(plus(null, 4), 4);
  assert.equal(plus(3, 4), 7);
  assert.equal(minus(null, 5), null, '总数未知，扣完仍未知');
  assert.equal(minus(10, null), 10);
  assert.equal(minus(3, 5), 0);
  assert.equal(isEmptyUsage(null, 0, undefined), true);
  assert.equal(isEmptyUsage(null, 1), false);
});

test('时间缺失或非法返回 null，不再是 1970', () => {
  for (const raw of [undefined, null, '', 0, 'not a date', Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(normalizeTimestamp(raw), null, `输入 ${String(raw)}`);
  }
  assert.equal(normalizeTimestamp(1792811311), '2026-10-24T03:08:31.000Z', '秒级时间戳');
  assert.equal(normalizeTimestamp(1792811311000), '2026-10-24T03:08:31.000Z', '毫秒级时间戳');
});

test('坏行跳过并计入 bad_lines', async () => {
  const notes = newNotes();
  const rows = await collect(jsonLines(Readable.from(['{"a":1}\n{broken\n\n{"a":2}\n']), notes));
  assert.deepEqual(rows, [{ a: 1 }, { a: 2 }]);
  assert.equal(notes.bad_lines, 1);
});

test('claude：没写的缓存字段记 null，流式快照合并时未知不压过已知', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-unknown-claude-'));
  try {
    const file = join(dir, 's.jsonl');
    const line = (u) => JSON.stringify({ sessionId: 's', timestamp: '2026-10-20T01:00:00.000Z', message: { id: 'msg_1', model: 'm', usage: u } });
    writeFileSync(file, [
      line({ input_tokens: 10, output_tokens: 0 }),
      line({ input_tokens: 10, output_tokens: 4, cache_read_input_tokens: 3 }),
      JSON.stringify({ sessionId: 's', timestamp: '2026-10-20T01:01:00.000Z', message: { id: 'msg_2', usage: { input_tokens: 0, output_tokens: 0 } } })
    ].join('\n') + '\n');

    const notes = newNotes();
    const [r] = await collect(parseClaude(file, notes));
    assert.equal(r.input_tokens, 10);
    assert.equal(r.output_tokens, 4);
    assert.equal(r.cache_read_tokens, 3);
    assert.equal(r.cache_write_tokens, null, '日志没写缓存写，就是未知');
    assert.equal(notes.zero_usage, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('codex：四类都为 0 的响应不入账并计 zero_usage', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-unknown-codex-'));
  try {
    const file = join(dir, 'rollout.jsonl');
    const rec = (id, usage) => JSON.stringify({ type: 'token_usage_record', timestamp: '2026-10-20T01:00:00.000Z',
      payload: { session_id: 'c', response_id: id, usage } });
    writeFileSync(file, [rec('r1', { input_tokens: 0, output_tokens: 0 }), rec('r2', { input_tokens: 5, cached_input_tokens: 2 })].join('\n') + '\n');

    const notes = newNotes();
    const records = await collect(parseCodex(file, notes));
    assert.equal(records.length, 1);
    assert.equal(records[0].input_tokens, 3);
    assert.equal(records[0].output_tokens, null);
    assert.equal(notes.zero_usage, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('采集把坏行、坏字段、缺时间、零用量记进本次运行的 counts', async () => {
  const root = mkdtempSync(join(tmpdir(), 'tl-unknown-ingest-'));
  const home = join(root, 'home');
  const data = join(root, 'data');
  const logDir = join(home, '.claude', 'projects', 'p');
  mkdirSync(logDir, { recursive: true });
  mkdirSync(data, { recursive: true });
  const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  try {
    const msg = (id, ts, usage) => JSON.stringify({ sessionId: 's', timestamp: ts, message: { id, model: 'm', usage } });
    writeFileSync(join(logDir, 's.jsonl'), [
      msg('msg_ok', '2026-10-20T01:00:00.000Z', { input_tokens: 10, output_tokens: 'abc' }),
      '{not json',
      msg('msg_notime', undefined, { input_tokens: 5, output_tokens: 5 }),
      msg('msg_zero', '2026-10-20T01:02:00.000Z', { input_tokens: 0, output_tokens: 0 })
    ].join('\n') + '\n');

    const result = await runIngestion({ dataDir: data });
    assert.equal(result.inserted, 1);
    assert.equal(result.counts.bad_lines, 1);
    assert.equal(result.counts.bad_fields, 1);
    assert.equal(result.counts.bad_times, 1);
    assert.equal(result.counts.zero_usage, 1);
    assert.deepEqual(result.anomalies, [], '这些计数不逐条进异常列表');

    const db = new DatabaseSync(join(data, 'ledger.db'), { readOnly: true });
    try {
      const row = db.prepare("SELECT output_tokens, cache_read_tokens FROM usage_records WHERE record_key = 'claude|msg_ok'").get();
      assert.equal(row.output_tokens, null, '非法值按未知入账');
      assert.equal(row.cache_read_tokens, null);
      const counts = JSON.parse(db.prepare('SELECT counts FROM ingest_runs ORDER BY id DESC LIMIT 1').get().counts);
      assert.equal(counts.bad_times, 1);
    } finally {
      db.close();
    }
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
    rmSync(root, { recursive: true, force: true });
  }
});
