import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, appendFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { parseCodex } from '../../src/core/adapters/codex.js';
import { parseClaude } from '../../src/core/adapters/claude.js';
import { parseDsh } from '../../src/core/adapters/dsh.js';
import { parseHermes } from '../../src/core/adapters/hermes.js';
import { parseQwen } from '../../src/core/adapters/qwen.js';
import { parsePi } from '../../src/core/adapters/pi.js';
import { parseTrae } from '../../src/core/adapters/trae.js';
import { Ledger } from '../../src/core/db/ledger.js';

const FIXTURES = new URL('../fixtures/', import.meta.url);
const CODEX_SAMPLE = fileURLToPath(new URL('codex/usage-sample.jsonl', FIXTURES));

async function collect(iterable) {
  const out = [];
  for await (const r of iterable) out.push(r);
  return out;
}

/**
 * 契约通用检查：新字段齐全，四类 token 互不重叠。
 */
function assertContract(records, source) {
  assert.ok(records.length > 0, `${source} 没有产出记录`);
  for (const r of records) {
    assert.equal(r.source, source);
    assert.equal(typeof r.record_key, 'string');
    assert.ok(r.record_key.length > 0, `${source} 记录缺 record_key`);
    assert.ok(r.observed_at, `${source} 记录缺 observed_at`);
    assert.equal(r.kind, records[0].kind);
    assert.ok(['event', 'cumulative'].includes(r.kind));
    for (const f of ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']) {
      const v = r[f];
      assert.ok(v === null || (Number.isInteger(v) && v >= 0), `${source}.${f} 非法：${v}`);
    }
  }
  const keys = new Set(records.map((r) => r.record_key));
  assert.equal(keys.size, records.length, `${source} 的 record_key 有重复`);
}

test('codex 真实样本：缓存读取不再丢失，且 input 扣掉缓存段', async () => {
  const records = await collect(parseCodex(CODEX_SAMPLE));
  assertContract(records, 'codex');

  const sum = records.reduce((a, r) => ({
    input: a.input + r.input_tokens,
    output: a.output + r.output_tokens,
    cached: a.cached + r.cache_read_tokens,
    gross: a.gross + r.input_tokens + r.output_tokens + r.cache_read_tokens
  }), { input: 0, output: 0, cached: 0, gross: 0 });

  assert.equal(records.length, 25);
  assert.equal(sum.cached, 2790144, '缓存读取必须等于原始 cached_input_tokens 合计');
  assert.equal(sum.input, 182840, 'input 必须是 input_tokens - cached_input_tokens');
  assert.equal(sum.output, 30681);
  assert.equal(sum.gross, 3003665, '落库 gross 必须等于客户端自报 total_tokens');
});

test('codex 每条记录的身份来自 response_id', async () => {
  const records = await collect(parseCodex(CODEX_SAMPLE));
  for (const r of records) {
    assert.match(r.record_key, /^codex\|.+\|/);
  }
  assert.ok(records.every((r) => r.kind === 'event'));
});

test('claude 跨轮用量增长：经账本后仍是一行，数值等于最新', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapters-'));
  try {
    const file = join(dir, 'session.jsonl');
    const line = (i, o, ts) => JSON.stringify({
      type: 'assistant',
      timestamp: ts,
      sessionId: 'sess-A',
      message: { id: 'msg_01', model: 'claude-opus-4-1', usage: { input_tokens: i, output_tokens: o } }
    }) + '\n';

    writeFileSync(file, line(100, 50, '2026-10-10T01:00:00.000Z'));
    const ledger = new Ledger(join(dir, 'ledger.db'));
    const first = await collect(parseClaude(file));
    assertContract(first, 'claude');
    ledger.write.ingestBatch(first);

    const firstTotals = ledger.read.totals();
    assert.equal(firstTotals.record_count, 1);
    assert.equal(firstTotals.input_tokens, 100);

    appendFileSync(file, line(200, 80, '2026-10-10T01:00:00.000Z'));
    ledger.write.ingestBatch(await collect(parseClaude(file)));

    const totals = ledger.read.totals();
    assert.equal(totals.record_count, 1, '同一消息不得残留第二行');
    assert.equal(totals.input_tokens, 200);
    assert.equal(totals.output_tokens, 80);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('dsh 全量覆写：经账本后仍是一行', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapters-'));
  try {
    const file = join(dir, 'session-dsh1.json');
    const doc = (i, o) => JSON.stringify({
      record: {
        identity: { createdAt: '2026-10-13T01:00:00.000Z' },
        rows: {
          tokenUsage: { val: { totals: { inputTokens: i, outputTokens: o } } },
          modelSelection: { val: { lastUsed: { model: 'deepseek-flash' } } }
        }
      }
    });

    writeFileSync(file, doc(500, 100));
    const ledger = new Ledger(join(dir, 'ledger.db'));
    const first = await collect(parseDsh(file));
    assertContract(first, 'dsh');
    assert.equal(first[0].kind, 'cumulative');
    ledger.write.ingestBatch(first);

    writeFileSync(file, doc(1500, 300));
    ledger.write.ingestBatch(await collect(parseDsh(file)));

    const totals = ledger.read.totals();
    assert.equal(totals.record_count, 1);
    assert.equal(totals.input_tokens, 1500);
    assert.equal(totals.output_tokens, 300);
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('hermes 累计增长：经账本后仍是一行（原实现会变成两行）', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapters-'));
  try {
    const dbFile = join(dir, 'state.db');
    const hdb = new DatabaseSync(dbFile);
    hdb.exec(`CREATE TABLE session_model_usage (
      session_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
      cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen TEXT)`);
    hdb.prepare(`INSERT INTO session_model_usage VALUES (?,?,?,?,?,?,?)`)
      .run('h1', 'hermes-3', 1000, 200, 0, 0, '2026-10-12T01:00:00.000Z');
    hdb.close();

    const ledger = new Ledger(join(dir, 'ledger.db'));
    const first = await collect(parseHermes(dbFile));
    assertContract(first, 'hermes');
    assert.equal(first[0].kind, 'cumulative');
    ledger.write.ingestBatch(first);
    assert.equal(ledger.read.totals().input_tokens, 1000);

    const hdb2 = new DatabaseSync(dbFile);
    hdb2.prepare(`UPDATE session_model_usage SET input_tokens=?, output_tokens=?, last_seen=? WHERE session_id='h1'`)
      .run(3000, 600, '2026-10-12T02:00:00.000Z');
    hdb2.close();

    ledger.write.ingestBatch(await collect(parseHermes(dbFile)));

    const totals = ledger.read.totals();
    assert.equal(totals.record_count, 1, '累计更新不得新增行');
    assert.equal(totals.input_tokens, 3000, '也不得累加成 4000');
    ledger.close();
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('codex：没有 token_usage_record 的行不产生记录', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapters-'));
  try {
    const file = join(dir, 'rollout-x.jsonl');
    writeFileSync(file, JSON.stringify({
      timestamp: '2026-10-17T11:39:40.000Z',
      type: 'event_msg',
      payload: { type: 'token_count', info: { last_token_usage: { input_tokens: 999, output_tokens: 9 } } }
    }) + '\n');
    const records = await collect(parseCodex(file));
    assert.equal(records.length, 0, 'token_count 事件与 token_usage_record 重复，不得计数');
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('qwen 真实样本：未缓存输入 + 思考 token 回算后等于客户端自报总量', async () => {
  const file = fileURLToPath(new URL('qwen/token-usage-sample.jsonl', FIXTURES));
  const records = await collect(parseQwen(file));
  assertContract(records, 'qwen');

  const sum = records.reduce((a, r) => ({
    input: a.input + r.input_tokens,
    output: a.output + r.output_tokens,
    cached: a.cached + r.cache_read_tokens,
    gross: a.gross + r.input_tokens + r.output_tokens + r.cache_read_tokens + r.cache_write_tokens
  }), { input: 0, output: 0, cached: 0, gross: 0 });

  assert.equal(records.length, 20);
  assert.equal(sum.input, 351131, 'inputTokens 必须扣掉 cachedTokens');
  assert.equal(sum.output, 19314, 'outputTags 必须并入 thoughtsTokens');
  assert.equal(sum.cached, 1112812);
  assert.equal(sum.gross, 1483257, '归一后应等于客户端自报 totalTokens 合计');
});

test('qwen 的身份来自账本条目 id，不是会话 id', async () => {
  const file = fileURLToPath(new URL('qwen/token-usage-sample.jsonl', FIXTURES));
  const records = await collect(parseQwen(file));

  for (const r of records) {
    const [source, session, entry] = r.record_key.split('|');
    assert.equal(source, 'qwen');
    assert.equal(session, r.session_id, '身份里的会话段必须等于 session_id');
    assert.ok(entry, '身份必须以条目 id 结尾');
    assert.ok(session.length > 0 && r.session_id !== r.record_key);
  }
  // 同一会话的多条记录不能共用身份
  assert.equal(new Set(records.map((r) => r.record_key)).size, records.length);
  assert.ok(new Set(records.map((r) => r.session_id)).size >= 1);
});

test('trae 会话汇总增长：身份不含时间，不得变成两行', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-adapters-'));
  let ledger;
  try {
    const file = join(dir, 'sessions.json');
    const doc = (ts, input, output) => JSON.stringify({
      sessions: [{ session_id: 'trae-s1', model_name: 'doubao-pro', usage_time: ts,
        input_token: input, output_token: output }]
    });

    writeFileSync(file, doc(1790000000, 100, 20));
    ledger = new Ledger(join(dir, 'ledger.db'));
    ledger.write.ingestBatch(await collect(parseTrae(file)));
    assert.equal(ledger.read.totals().input_tokens, 100);

    writeFileSync(file, doc(1790003600, 300, 60));
    ledger.write.ingestBatch(await collect(parseTrae(file)));

    const totals = ledger.read.totals();
    assert.equal(totals.record_count, 1, '时间变化不得产生第二行');
    assert.equal(totals.input_tokens, 300, '也不得累加成 400');
  } finally {
    if (ledger) ledger.close();
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('pi 真实样本：消息级身份唯一，四项 token 直接透传', async () => {
  const file = fileURLToPath(new URL('pi/session-sample.jsonl', FIXTURES));
  const records = await collect(parsePi(file));
  assertContract(records, 'pi');

  const sum = records.reduce((a, r) => ({
    input: a.input + r.input_tokens,
    output: a.output + r.output_tokens,
    cached: a.cached + r.cache_read_tokens
  }), { input: 0, output: 0, cached: 0 });

  assert.equal(sum.input, 70947);
  assert.equal(sum.output, 38957);
  assert.equal(sum.cached, 887168, 'pi 的 input 不含缓存，无需扣减');
  assert.ok(records.every((r) => r.kind === 'event'));
});
