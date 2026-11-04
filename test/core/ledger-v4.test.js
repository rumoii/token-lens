import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { Ledger } from '../../src/core/db/ledger.js';
import { payloadHash } from '../../src/core/db/write.js';
import { adapters } from '../../src/core/adapters/index.js';
import { runIngestion } from '../../src/core/ingest.js';
import { costOf } from '../../src/core/pricing/engine.js';

const priceOf = (r) => costOf(r);

function rec(key, over = {}) {
  return {
    record_key: key, source: 'claude', session_id: 's', model: 'claude-opus-5-5',
    observed_at: '2026-10-20T01:00:00.000Z', kind: 'event',
    input_tokens: 10, output_tokens: 20, cache_read_tokens: 0, cache_write_tokens: 0,
    ...over
  };
}

const active = (ledger) => ledger.read.totals({}).gross_tokens;

test('v3 账本升到当前版本：只加列，行数、四类 token、金额不变，新列为空', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-v4-migrate-'));
  try {
    const file = join(dir, 'ledger.db');
    const ledger = new Ledger(file);
    ledger.write.ingestBatch([rec('k1'), rec('k2', { output_tokens: 5, kind: 'cumulative', record_key: 'k2' })], { priceOf });
    const before = ledger.read.totals({});
    ledger.close();

    // 退回 v3 的表结构：去掉 v4 新增的列与索引
    const raw = new DatabaseSync(file);
    raw.exec(`
      DROP INDEX idx_usage_file;
      ALTER TABLE usage_records DROP COLUMN source_file;
      ALTER TABLE usage_records DROP COLUMN parser_rev;
      ALTER TABLE ingest_runs DROP COLUMN counts;
      PRAGMA user_version = 3;
    `);
    raw.close();

    const migrated = new Ledger(file);
    try {
      assert.deepEqual(migrated.read.totals({}), before);
    } finally { migrated.close(); }
    const check = new DatabaseSync(file, { readOnly: true });
    try {
      assert.equal(check.prepare('PRAGMA user_version').get().user_version, 5);
      const row = check.prepare('SELECT count(*) n, sum(source_file IS NULL) f, sum(parser_rev IS NULL) r FROM usage_records').get();
      assert.deepEqual({ ...row }, { n: 2, f: 2, r: 2 });
    } finally { check.close(); }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('按文件找活跃行走 source_file 复合索引，不退化成扫描全部活跃行', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-v4-plan-'));
  try {
    const file = join(dir, 'ledger.db');
    new Ledger(file).close();
    // 查询与 write.js 的 #fileRows 一致；没有它时规划器会选区分度很低的 active 索引
    const db = new DatabaseSync(file, { readOnly: true });
    try {
      const plan = db.prepare('EXPLAIN QUERY PLAN SELECT id, record_key, parser_rev FROM usage_records WHERE source_file = ? AND active = 1')
        .all('/logs/a.jsonl').map((r) => r.detail).join('\n');
      assert.match(plan, /idx_usage_file/);
    } finally { db.close(); }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('内容指纹覆盖时间与缓存写分档：只有这些变了也写回', () => {
  const base = rec('k');
  assert.notEqual(payloadHash(base), payloadHash({ ...base, observed_at: '2026-10-21T01:00:00.000Z' }));
  assert.notEqual(payloadHash(base), payloadHash({ ...base, cache_write_1h_tokens: 0, cache_write_5m_tokens: 0 }));

  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('k', { cache_write_tokens: 1000 })], { priceOf });
    const stats = ledger.write.ingestBatch([rec('k', {
      observed_at: '2026-10-21T00:30:00.000Z', cache_write_tokens: 1000,
      cache_write_5m_tokens: 0, cache_write_1h_tokens: 1000
    })], { priceOf });
    assert.equal(stats.updated, 1);
    const [day] = ledger.read.timeseries('day', {}).points;
    assert.equal(day.bucket, '2026-10-21');
  } finally { ledger.close(); }
});

test('同一版解析器下文件里的记录消失：保留原值，计为 vanished', () => {
  const ledger = new Ledger(':memory:');
  try {
    const opts = { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 1 };
    ledger.write.ingestBatch([rec('k1'), rec('k2')], opts);
    const stats = ledger.write.ingestBatch([rec('k1')], opts);
    assert.equal(stats.counts.vanished, 1);
    assert.equal(stats.counts.deactivated, 0);
    assert.equal(active(ledger), 60);
    assert.match(stats.anomalies.join('\n'), /vanished/);
  } finally { ledger.close(); }
});

test('解析器版本变了，旧口径独有的产出被停用，总额随之下降', () => {
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('k1'), rec('k2')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 1 });
    const stats = ledger.write.ingestBatch([rec('k1')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 2 });
    assert.equal(stats.counts.deactivated, 1);
    assert.equal(active(ledger), 30);

    // 别的文件的行不受影响
    ledger.write.ingestBatch([rec('k3')], { priceOf, sourceFile: '/logs/b.jsonl', parserRev: 1 });
    ledger.write.ingestBatch([rec('k1')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 3 });
    assert.equal(active(ledger), 60);
  } finally { ledger.close(); }
});

test('一条都没产出的文件不停用任何行：分不清空文件与被吞掉的读取失败', () => {
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('k1')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 1 });
    const stats = ledger.write.ingestBatch([], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 2 });
    assert.equal(stats.counts.deactivated, 0);
    assert.equal(active(ledger), 30);
  } finally { ledger.close(); }
});

test('被停用的行再次产出时恢复计入', () => {
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('k1'), rec('k2')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 1 });
    ledger.write.ingestBatch([rec('k1')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 2 });
    const stats = ledger.write.ingestBatch([rec('k1'), rec('k2')], { priceOf, sourceFile: '/logs/a.jsonl', parserRev: 2 });
    assert.equal(stats.counts.reactivated, 1);
    assert.equal(active(ledger), 60);
  } finally { ledger.close(); }
});

test('replaces：旧键停用并指向新行，新旧不重复计数', () => {
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('claude|s|msg_1')], { priceOf });
    const stats = ledger.write.ingestBatch([rec('claude|msg_1', { replaces: ['claude|s|msg_1'] })], { priceOf });
    assert.equal(stats.counts.replaced, 1);
    assert.equal(active(ledger), 30);
    const rows = ledger.read.sessions({}).items;
    assert.equal(rows[0].record_count, 1);

    // 旧键又被产出（新旧解析器同时在跑）：不恢复，报异常
    const again = ledger.write.ingestBatch([rec('claude|s|msg_1')], { priceOf });
    assert.match(again.anomalies.join('\n'), /superseded_reproduced/);
    assert.equal(active(ledger), 30);
  } finally { ledger.close(); }
});

test('累计值下降：解析器版本变了才接受，版本未登记按第 1 版处理', () => {
  const ledger = new Ledger(':memory:');
  try {
    const cum = (n) => rec('dsh|s', { source: 'dsh', kind: 'cumulative', input_tokens: n, output_tokens: 0 });
    ledger.write.ingestBatch([cum(1000)], { priceOf });

    const sameRev = ledger.write.ingestBatch([cum(600)], { priceOf, parserRev: 1 });
    assert.equal(sameRev.counts.cumulative_decrease, 1);
    assert.equal(active(ledger), 1000);

    const newRev = ledger.write.ingestBatch([cum(600)], { priceOf, parserRev: 2 });
    assert.equal(newRev.counts.rev_corrections, 1);
    assert.equal(active(ledger), 600);

    const stillTwo = ledger.write.ingestBatch([cum(500)], { priceOf, parserRev: 2 });
    assert.equal(stillTwo.counts.cumulative_decrease, 1);
    assert.equal(active(ledger), 600);
  } finally { ledger.close(); }
});

test('解析器这次没给出项目或结束时间时，不清掉原来的值', () => {
  const ledger = new Ledger(':memory:');
  try {
    ledger.write.ingestBatch([rec('k', { project_key: '/w/app', kind: 'cumulative', ended_at: '2026-10-20T02:00:00.000Z' })], { priceOf });
    ledger.write.ingestBatch([rec('k', { project_key: null, kind: 'cumulative', ended_at: null, input_tokens: 99 })], { priceOf });
    const s = ledger.read.sessions({}).items[0];
    assert.equal(s.project_key, '/w/app');
    assert.equal(s.last_seen_at, '2026-10-20T02:00:00.000Z');
  } finally { ledger.close(); }
});

/**
 * 在临时 HOME 下跑真实的 runIngestion：发现函数在调用时读 HOME，适配器可在进程内替换。
 */
async function withHome(fn) {
  const root = mkdtempSync(join(tmpdir(), 'tl-v4-ingest-'));
  const home = join(root, 'home');
  const data = join(root, 'data');
  mkdirSync(join(home, '.claude', 'projects', 'p'), { recursive: true });
  mkdirSync(data, { recursive: true });
  const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  const original = adapters.claude;
  try {
    await fn({ home, data, logDir: join(home, '.claude', 'projects', 'p') });
  } finally {
    adapters.claude = original;
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
    rmSync(root, { recursive: true, force: true });
  }
}

const runRows = (data) => {
  const db = new DatabaseSync(join(data, 'ledger.db'), { readOnly: true });
  try { return db.prepare('SELECT status, started_at, finished_at, counts FROM ingest_runs ORDER BY id').all(); }
  finally { db.close(); }
};

test('解析中途失败的文件一条都不入库，也不停用该文件已有的行', async () => {
  await withHome(async ({ data, logDir }) => {
    const file = join(logDir, 's.jsonl');
    writeFileSync(file, '{}\n');
    adapters.claude = async function* () { yield rec('k1'); yield rec('k2'); };
    await runIngestion({ dataDir: data });

    adapters.claude = async function* () { yield rec('k1', { output_tokens: 999 }); throw new Error('simulated read failure'); };
    const result = await runIngestion({ dataDir: data });
    assert.equal(result.counts.read_failed, 1);
    assert.equal(result.inserted + result.updated, 0);

    const ledger = new Ledger(join(data, 'ledger.db'));
    try { assert.equal(ledger.read.totals({}).gross_tokens, 60); }
    finally { ledger.close(); }
  });
});

test('采集进行中能看到 running 运行记录，结束后带真实开始时间与按类计数', async () => {
  await withHome(async ({ data, logDir }) => {
    writeFileSync(join(logDir, 's.jsonl'), '{}\n');
    let during = null;
    adapters.claude = async function* () {
      during = runRows(data).at(-1)?.status ?? null;
      yield rec('k1');
    };
    await runIngestion({ dataDir: data });
    assert.equal(during, 'running');

    const [run] = runRows(data);
    assert.equal(run.status, 'ok');
    assert.ok(run.finished_at >= run.started_at);
    const counts = JSON.parse(run.counts);
    assert.equal(counts.read_failed, 0);
    assert.equal(counts.vanished, 0);

    const ledger = new Ledger(join(data, 'ledger.db'));
    try { assert.deepEqual(ledger.read.lastRun().counts, counts); }
    finally { ledger.close(); }
  });
});

test('上一次运行没走到收尾时，下一次运行把它标成 abandoned', async () => {
  await withHome(async ({ data }) => {
    const ledger = new Ledger(join(data, 'ledger.db'));
    try { ledger.write.beginRun(); } finally { ledger.close(); }
    await runIngestion({ dataDir: data });
    assert.deepEqual(runRows(data).map((r) => r.status), ['abandoned', 'ok']);
  });
});
