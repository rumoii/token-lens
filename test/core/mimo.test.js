import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseMimo } from '../../src/core/adapters/mimo.js';
import { parseOpencode } from '../../src/core/adapters/opencode.js';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';
import { costOf } from '../../src/core/pricing/engine.js';

// MiMo Code 是 OpenCode 的分支（github.com/XiaomiMiMo/MiMo-Code）：用量在 mimocode.db，
// message 表与 OpenCode v1 同构，每条 assistant 消息的 data JSON 里
// tokens = { input, output, reasoning, cache: { read, write } }。建表与插数照 opencode.test.js 的 v1 fixture。
//
// specs/adapters.md 第五节 7 个用例里两条不适用，理由：
// - 第 4 条（累计快照变化 → 覆盖，不累加）：message 表逐条 assistant 消息都是事件（kind = 'event'），
//   MiMo Code 不在库里存整场会话的累计快照，没有可覆盖的快照。
// - 第 7 条（与客户端自报总量对照 → 差额为 0）：mimocode.db 只有逐条用量，
//   客户端没有自报的会话总量字段，没有可对照的 oracle。

const created = 1792960000000;

const message = (fields = {}) => ({
  role: 'assistant', type: 'assistant', modelID: 'mimo-v2.6-pro',
  tokens: { input: 100, output: 20, reasoning: 5, cache: { read: 30, write: 10 } },
  ...fields
});

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'tl-mimo-'));
  const file = join(root, 'mimocode.db');
  const db = new DatabaseSync(file);
  const ledger = new Ledger(':memory:');
  t.after(() => {
    try { ledger.close(); } finally {
      try { db.close(); } finally { rmSync(root, { recursive: true, force: true }); }
    }
  });
  db.exec(`
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_updated INTEGER, time_created INTEGER, data TEXT);
    CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT);
  `);
  const put = (id, data = message(), { session = 'ses_1', time = created } = {}) => {
    db.prepare('INSERT OR REPLACE INTO message VALUES (?, ?, ?, ?, ?, ?)').run(
      id, session, 'assistant', time, time, typeof data === 'string' ? data : JSON.stringify(data)
    );
  };
  const parse = async (path = file, notes) => {
    assert.equal(typeof adapters.mimo, 'function', 'mimo parser must be registered');
    return Array.fromAsync(adapters.mimo(path, notes));
  };
  const ingest = async (path = file, notes) => ledger.write.ingestBatch(await parse(path, notes), {
    priceOf: costOf, sourceFile: path, parserRev: PARSER_REV.mimo
  });
  return { root, file, db, ledger, put, parse, ingest };
}

test('mimo normal: values and fields from the mimocode.db message table', async (t) => {
  assert.equal(PARSER_REV.mimo, 4);
  const f = fixture(t);
  f.db.exec("INSERT INTO session VALUES ('ses_1', 'D:/work/one/')");
  f.put('msg_1');
  const rows = await f.parse();
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0], {
    record_key: 'mimo|ses_1|msg_1', source: 'mimo', session_id: 'ses_1', project_key: 'D:\\work\\one',
    model: 'mimo-v2.6-pro', provider: null, observed_at: '2026-10-25T20:26:40.000Z', kind: 'event',
    input_tokens: 100, output_tokens: 25, cache_read_tokens: 30, cache_write_tokens: 10,
    cache_creation_tokens: 10
  });
  assert.ok(rows.every(row => row.kind === 'event'), 'message 表只产事件，无累计快照（第 4 条不适用）');
});

test('mimo parity: same usage as parseOpencode, without the obsolete timestamp alias', async (t) => {
  const f = fixture(t);
  f.db.exec("INSERT INTO session VALUES ('ses_1', 'D:/work/one/')");
  f.put('msg_1');
  f.put(null, message(), { session: 'ses_2', time: created + 1000 });
  f.put('msg_nomodel', message({ modelID: undefined, model: undefined }));
  f.put('msg_provider', message({ modelID: undefined, model: { id: 'mimo-v2.6-pro', providerID: 'xiaomi' } }));
  const mimoRows = await f.parse();
  const openRows = await Array.fromAsync(parseOpencode(f.file));
  assert.equal(mimoRows.length, 4);
  assert.deepEqual(mimoRows, await f.parse(), '同一库重复解析逐字段一致');
  assert.ok(mimoRows.every(row => row.source === 'mimo' && row.record_key.startsWith('mimo|')));
  assert.ok(openRows.every(row => row.source === 'opencode' && row.record_key.startsWith('opencode|')));
  const strip = key => key.replace(/^[^|]+\|/, 'src|');
  const normalize = ({ timestamp, ...row }) => ({
    ...row, source: 'src', record_key: strip(row.record_key),
    ...(row.replaces ? { replaces: row.replaces.map(strip) } : {})
  });
  assert.ok(mimoRows.every(row => !Object.hasOwn(row, 'timestamp')));
  assert.deepEqual(mimoRows.map(normalize), openRows.map(normalize), '除来源名、键前缀与旧时间别名外逐字段相等');
});

test('mimo repeat collection: rows, totals and cost stay unchanged', async (t) => {
  const f = fixture(t);
  f.put('msg_1');
  f.put('msg_2');
  await f.ingest();
  const before = f.ledger.read.totals();
  assert.ok(before.cost_micros > 0);
  const again = await f.ingest();
  assert.equal(again.inserted, 0);
  assert.equal(again.unchanged, 2);
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('mimo growth: message updates rewrite the row, new messages append', async (t) => {
  const f = fixture(t);
  f.put('msg_1');
  await f.ingest();
  f.put('msg_1', message({ tokens: { input: 200, output: 40, reasoning: 10 } }));
  const growth = await f.ingest();
  assert.equal(growth.updated, 1);
  assert.equal(growth.inserted, 0);
  assert.equal(f.ledger.read.totals().record_count, 1);
  assert.equal(f.ledger.read.totals().input_tokens, 200);
  assert.equal(f.ledger.read.totals().output_tokens, 50);
  f.put('msg_2');
  const append = await f.ingest();
  assert.equal(append.inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
});

test('mimo rotation: a copied db does not count twice', async (t) => {
  const f = fixture(t);
  f.put('msg_1');
  f.put('msg_2');
  await f.ingest();
  const before = f.ledger.read.totals();
  const rotated = join(f.root, 'rotated.db');
  copyFileSync(f.file, rotated);
  const copy = await f.ingest(rotated);
  assert.equal(copy.inserted, 0);
  assert.equal(copy.unchanged, 2);
  assert.deepEqual(f.ledger.read.totals(), before);
  // 截断（删行）后用量不丢的语义在下面的 vanished 用例里单独验证。
});

test('mimo bad rows and missing fields: counted separately, unknown stays NULL', async (t) => {
  const f = fixture(t);
  f.put('msg_bad_json', '{');
  f.put('msg_zero', message({ tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } } }));
  f.put('msg_bad_fields', message({ tokens: { output: 'x', cache: { read: -1, write: 2 } } }));
  f.put('msg_no_tokens', message({ tokens: undefined }));
  f.put('msg_bad_time', message(), { time: 'invalid' });
  f.put('msg_ok');
  const notes = newNotes();
  const rows = await f.parse(f.file, notes);
  const bad = rows.find(row => row.record_key === 'mimo|ses_1|msg_bad_fields');
  assert.deepEqual(
    { input: bad.input_tokens, output: bad.output_tokens, read: bad.cache_read_tokens, write: bad.cache_write_tokens },
    { input: null, output: null, read: null, write: 2 },
    '缺字段与坏值保持 null，不写 0'
  );
  const late = rows.find(row => row.record_key === 'mimo|ses_1|msg_bad_time');
  assert.equal(late.observed_at, null, '时间非法的记录带 null 时间产出，由 ingest/runIngestion 计 bad_times 后丢弃');
  assert.deepEqual(notes, { bad_lines: 1, bad_fields: 2, zero_usage: 1, bad_times: 0 });
  const stats = await f.ingest(f.file, notes);
  assert.equal(stats.rejected, 1);
  assert.match(stats.anomalies.join('\n'), /缺少 observed_at/);
  const total = f.ledger.read.totals();
  assert.equal(total.record_count, 2, '坏行不污染统计，只有 msg_bad_fields 与 msg_ok 入账');
  assert.equal(total.gross_tokens, 167);
});

test('mimo vanished: a row deleted from the db stays active and totals keep counting', async (t) => {
  const f = fixture(t);
  f.put('msg_1');
  f.put('msg_2');
  const ledgerDb = openLedger(':memory:');
  t.after(() => ledgerDb.close());
  const writer = new LedgerWriter(ledgerDb);
  const opts = { priceOf: costOf, sourceFile: f.file, parserRev: PARSER_REV.mimo };
  const state = () => ledgerDb.prepare(
    `SELECT record_key, active,
            coalesce(input_tokens, 0) + coalesce(output_tokens, 0) + coalesce(cache_read_tokens, 0) + coalesce(cache_write_tokens, 0) AS gross
     FROM usage_records ORDER BY record_key`
  ).all();
  assert.equal(writer.ingestBatch(await f.parse(), opts).inserted, 2);
  const before = state();
  assert.deepEqual(before.map(row => row.active), [1, 1]);
  f.db.exec("DELETE FROM message WHERE id = 'msg_2'");
  const second = writer.ingestBatch(await f.parse(), opts);
  assert.equal(second.counts.vanished, 1);
  assert.ok(second.anomalies.some(text => text.includes('vanished')));
  assert.deepEqual(state(), before, '消失的行仍 active = 1，总量不变');
});
