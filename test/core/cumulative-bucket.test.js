import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger, SCHEMA_VERSION } from '../../src/core/db/open.js';
import { parseDsh } from '../../src/core/adapters/dsh.js';

const tokens = { input_tokens: 100, output_tokens: 10, cache_read_tokens: 1000, cache_write_tokens: 0 };

function seed(ledger) {
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'e1', session_id: 'a', model: 'm', observed_at: '2026-10-18T02:00:00.000Z', kind: 'event', ...tokens },
    // 同一天开始、同一天结束：能归入 10-18
    { source: 'dsh', record_key: 'dsh|same', session_id: 'same', model: 'deepseek-flash', kind: 'cumulative',
      observed_at: '2026-10-18T01:00:00.000Z', ended_at: '2026-10-18T09:00:00.000Z', ...tokens },
    // 跨天：留在 unallocated
    { source: 'dsh', record_key: 'dsh|span', session_id: 'span', model: 'deepseek-flash', kind: 'cumulative',
      observed_at: '2026-10-17T20:00:00.000Z', ended_at: '2026-10-18T03:00:00.000Z', ...tokens },
    // 不知道何时结束：留在 unallocated
    { source: 'dsh', record_key: 'dsh|open', session_id: 'open', model: 'deepseek-flash', kind: 'cumulative',
      observed_at: '2026-10-18T05:00:00.000Z', ...tokens }
  ]);
}

const gross = 1110;

test('同一个桶内结束的累计快照计入该桶，其余进 unallocated，合计仍等于总额', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  const { points, unallocated } = ledger.read.timeseries('day');
  const day = points.find((p) => p.bucket === '2026-10-18');
  assert.equal(day.gross_tokens, gross * 2, '事件 + 同日快照');
  assert.equal(unallocated.gross_tokens, gross * 2, '跨天快照 + 无结束时间的快照');
  assert.equal(unallocated.record_count, 2);

  const sum = points.reduce((s, p) => s + p.gross_tokens, 0) + unallocated.gross_tokens;
  assert.equal(sum, ledger.read.totals().gross_tokens);

  const grouped = ledger.read.timeseriesGrouped('day', 'source');
  const dshDay = grouped.rows.find((r) => r.bucket === '2026-10-18' && r.group === 'dsh');
  assert.equal(dshDay.gross_tokens, gross);
  assert.equal(grouped.unallocated.gross_tokens, gross * 2);
  ledger.close();
});

test('桶边界跟着时区和粒度走', () => {
  const ledger = new Ledger(':memory:');
  seed(ledger);

  // +08:00 下，跨天那条是 10-18 04:00 → 11:00，同一天
  const shifted = ledger.read.timeseries('day', { offsetMinutes: 480 });
  assert.equal(shifted.unallocated.record_count, 1, '只剩没有结束时间的那条');

  // 按小时：同日快照跨了 8 个小时，进不了任何一个小时桶
  const hourly = ledger.read.timeseries('hour');
  assert.equal(hourly.unallocated.record_count, 3);

  // 按月：三条都开始结束在同一个月，除了没有结束时间的
  const monthly = ledger.read.timeseries('month');
  assert.equal(monthly.unallocated.record_count, 1);
  ledger.close();
});

test('用量没变时也回填 ended_at，会话时长随之变真实', () => {
  const ledger = new Ledger(':memory:');
  const base = { source: 'dsh', record_key: 'dsh|x', session_id: 'x', model: 'deepseek-flash', kind: 'cumulative',
    observed_at: '2026-10-18T01:00:00.000Z', ...tokens };
  ledger.write.ingestBatch([base]);
  const before = ledger.read.sessions().items[0];
  assert.equal(before.last_seen_at, before.started_at, '没有结束时间时只有一个时间点');

  const stats = ledger.write.ingestBatch([{ ...base, ended_at: '2026-10-18T03:30:00.000Z' }]);
  // 最后活动时间在内容指纹里（schema v4）：回填按更新处理，revision 加一，用量与金额不变
  assert.equal(stats.updated, 1);
  assert.equal(stats.unchanged, 0);

  const after = ledger.read.sessions().items[0];
  assert.equal(after.started_at, '2026-10-18T01:00:00.000Z');
  assert.equal(after.last_seen_at, '2026-10-18T03:30:00.000Z');
  assert.equal(ledger.read.timeseries('day').unallocated, null, '回填后能归入当天');

  const again = ledger.write.ingestBatch([{ ...base, ended_at: '2026-10-18T03:30:00.000Z' }]);
  assert.equal(again.unchanged, 1);
  ledger.close();
});

test('v2 账本升到 v3：加 ended_at 列，旧行为空，行数与总额不变', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-migrate-v3-'));
  const dbPath = join(dir, 'ledger.db');
  const seeded = openLedger(dbPath);
  seeded.close();

  // 回退成 v2：去掉 ended_at 列并写一条旧行
  const raw = new DatabaseSync(dbPath);
  raw.exec('ALTER TABLE usage_records DROP COLUMN ended_at');
  raw.prepare(`
    INSERT INTO usage_records (record_key, content_hash, source, session_id, model, observed_at, kind,
      input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_micros)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
  `).run('dsh|old', 'h', 'dsh', 'old', 'deepseek-flash', '2026-10-18T01:00:00.000Z', 'cumulative', 1, 2, 3, 4, 99);
  raw.exec('PRAGMA user_version = 2');
  raw.close();

  const ledger = new Ledger(dbPath);
  assert.equal(ledger.read.totals().gross_tokens, 10);
  assert.equal(ledger.read.timeseries('day').unallocated.record_count, 1, '旧行 ended_at 未知，仍不归日');
  ledger.close();

  const db = new DatabaseSync(dbPath);
  assert.equal(Number(db.prepare('PRAGMA user_version').get().user_version), SCHEMA_VERSION);
  assert.equal(SCHEMA_VERSION, 5);
  assert.equal(db.prepare("SELECT ended_at FROM usage_records WHERE record_key = 'dsh|old'").get().ended_at, null);
  db.close();
  rmSync(dir, { recursive: true, force: true });
});

test('DSH 适配器读出最后一条消息时间；缺失或早于开始时间按未知处理', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-dsh-ended-'));
  const make = (name, timeContext) => {
    const file = join(dir, `session-${name}.json`);
    writeFileSync(file, JSON.stringify({
      record: {
        identity: { createdAt: Date.parse('2026-10-18T01:00:00.000Z') },
        rows: {
          tokenUsage: { val: { totals: { uncachedInputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0 } } },
          ...(timeContext ? { timeContext: { val: timeContext } } : {})
        }
      }
    }));
    return file;
  };
  const first = async (file) => { for await (const r of parseDsh(file)) return r; return null; };

  const ok = await first(make('ok', { lastMessageTime: Date.parse('2026-10-18T09:00:00.000Z') }));
  assert.equal(ok.ended_at, '2026-10-18T09:00:00.000Z');
  assert.equal((await first(make('none', null))).ended_at, null);
  const early = await first(make('early', { lastMessageTime: Date.parse('2026-10-17T09:00:00.000Z') }));
  assert.equal(early.ended_at, null);
  rmSync(dir, { recursive: true, force: true });
});
