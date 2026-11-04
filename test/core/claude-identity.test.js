import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Ledger } from '../../src/core/db/ledger.js';
import { parseClaude } from '../../src/core/adapters/claude.js';
import { discoverAll } from '../../src/core/discovery.js';
import { runIngestion } from '../../src/core/ingest.js';

const usage = (i, o) => ({ input_tokens: i, output_tokens: o, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 });

const line = (sessionId, ts, id, u, extra = {}) => JSON.stringify({
  type: 'assistant', sessionId, timestamp: ts, uuid: `u-${id}`,
  message: { id, model: 'claude-opus-5-5', usage: u }, ...extra
});

async function collect(it) {
  const out = [];
  for await (const r of it) out.push(r);
  return out;
}

test('claude 身份只含 message.id，并用 replaces 指向第 1 版的会话内键；缺模型记 null', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-claude-key-'));
  try {
    const file = join(dir, 's.jsonl');
    writeFileSync(file, [
      line('sA', '2026-10-20T01:00:00.000Z', 'msg_1', usage(10, 5)),
      JSON.stringify({ type: 'assistant', sessionId: 'sA', timestamp: '2026-10-20T01:01:00.000Z',
        message: { id: 'msg_2', usage: usage(3, 1) } })
    ].join('\n') + '\n');

    const [first, second] = await collect(parseClaude(file));
    assert.equal(first.record_key, 'claude|msg_1');
    assert.deepEqual(first.replaces, ['claude|sA|msg_1']);
    assert.equal(first.session_id, 'sA');
    assert.equal(second.model, null, '日志没写模型就是未知，不写成 unknown');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('没有 message.id 的行用 uuid，连 uuid 都没有才用文件与行号', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-claude-orphan-'));
  try {
    const file = join(dir, 's.jsonl');
    writeFileSync(file, [
      JSON.stringify({ sessionId: 'sA', timestamp: '2026-10-20T01:00:00.000Z', uuid: 'uuid-1', usage: usage(1, 1) }),
      '',
      JSON.stringify({ sessionId: 'sA', timestamp: '2026-10-20T01:00:01.000Z', usage: usage(2, 2) })
    ].join('\n') + '\n');

    const records = await collect(parseClaude(file));
    assert.equal(records[0].record_key, 'claude|uuid-1');
    assert.deepEqual(records[0].replaces, ['claude|sA|#1']);
    assert.match(records[1].record_key, /^claude\|f[0-9a-f]{12}:3$/, '行号按物理行计，空行也算');
    assert.deepEqual(records[1].replaces, ['claude|sA|#2']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * 临时 HOME 下的两份 claude 会话：原始会话 sA，以及分支出来、复制了 msg_1 的 sB。
 * 复制文件按路径排在前面，用来确认取舍不依赖处理顺序。
 */
async function withForkedSessions(fn) {
  const root = mkdtempSync(join(tmpdir(), 'tl-claude-fork-'));
  const home = join(root, 'home');
  const data = join(root, 'data');
  const logDir = join(home, '.claude', 'projects', 'p');
  mkdirSync(logDir, { recursive: true });
  mkdirSync(data, { recursive: true });
  const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  try {
    writeFileSync(join(logDir, 'z-original.jsonl'), [
      line('sA', '2026-10-20T01:00:00.000Z', 'msg_0', usage(100, 10)),
      line('sA', '2026-10-20T01:05:00.000Z', 'msg_1', usage(200, 20))
    ].join('\n') + '\n');
    writeFileSync(join(logDir, 'a-fork.jsonl'), [
      JSON.stringify({ type: 'user', sessionId: 'sB', timestamp: '2026-10-20T02:00:00.000Z' }),
      line('sB', '2026-10-20T01:05:00.000Z', 'msg_1', usage(200, 20)),
      line('sB', '2026-10-20T02:01:00.000Z', 'msg_2', usage(300, 30))
    ].join('\n') + '\n');
    await fn({ data, files: discoverAll().claude });
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
    rmSync(root, { recursive: true, force: true });
  }
}

test('复制进另一会话的消息只计一次，归原始会话；第 1 版的两行都被接替', async () => {
  await withForkedSessions(async ({ data, files }) => {
    // 第 1 版的产出：msg_1 在两个会话里各有一行，重复计数
    const v1 = new Ledger(join(data, 'ledger.db'));
    const fork = files.find((f) => f.endsWith('a-fork.jsonl'));
    const original = files.find((f) => f.endsWith('z-original.jsonl'));
    const old = (session, id, i, o, ts) => ({
      record_key: `claude|${session}|${id}`, source: 'claude', session_id: session, model: 'claude-opus-5-5',
      observed_at: ts, kind: 'event', input_tokens: i, output_tokens: o, cache_read_tokens: 0, cache_write_tokens: 0
    });
    v1.write.ingestBatch([old('sA', 'msg_0', 100, 10, '2026-10-20T01:00:00.000Z'), old('sA', 'msg_1', 200, 20, '2026-10-20T01:05:00.000Z')],
      { sourceFile: original, parserRev: 1 });
    v1.write.ingestBatch([old('sB', 'msg_1', 200, 20, '2026-10-20T01:05:00.000Z'), old('sB', 'msg_2', 300, 30, '2026-10-20T02:01:00.000Z')],
      { sourceFile: fork, parserRev: 1 });
    assert.equal(v1.read.totals({}).gross_tokens, 110 + 220 * 2 + 330);
    v1.close();

    const result = await runIngestion({ dataDir: data });
    assert.equal(result.counts.cross_file_copies, 1);
    assert.equal(result.counts.replaced, 4, '四条旧键都由新键接替');
    assert.equal(result.counts.deactivated, 0);
    assert.equal(result.counts.vanished, 0);
    assert.deepEqual(result.anomalies, []);

    const ledger = new Ledger(join(data, 'ledger.db'));
    try {
      assert.equal(ledger.read.totals({}).gross_tokens, 110 + 220 + 330);
      const sessions = Object.fromEntries(ledger.read.sessions().items.map((s) => [s.session_id, s.gross_tokens]));
      assert.deepEqual(sessions, { sA: 330, sB: 330 }, 'msg_1 归开始更早的原始会话');
    } finally {
      ledger.close();
    }

    const again = await runIngestion({ dataDir: data });
    assert.equal(again.inserted + again.updated, 0, '取舍是确定的，第二次运行不来回改写');
    assert.equal(again.unchanged, 3);
    assert.deepEqual(again.anomalies, []);
  });
});

test('原始会话的日志删掉后，复制的那份接手计数', async () => {
  await withForkedSessions(async ({ data, files }) => {
    await runIngestion({ dataDir: data });
    rmSync(files.find((f) => f.endsWith('z-original.jsonl')));

    const result = await runIngestion({ dataDir: data });
    assert.equal(result.counts.cross_file_copies, 0);
    const ledger = new Ledger(join(data, 'ledger.db'));
    try {
      // msg_0 只在删掉的文件里，仍然计入；msg_1 改由 sB 的文件产出
      assert.equal(ledger.read.totals({}).gross_tokens, 110 + 220 + 330);
      const sessions = Object.fromEntries(ledger.read.sessions().items.map((s) => [s.session_id, s.gross_tokens]));
      assert.deepEqual(sessions, { sA: 110, sB: 550 });
    } finally {
      ledger.close();
    }
  });
});
