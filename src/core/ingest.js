import { discoverAll } from './discovery.js';
import { adapters, parserRevOf } from './adapters/index.js';
import { newNotes, note } from './adapters/_num.js';
import { Ledger } from './db/ledger.js';
import { costOf, PRICE_VERSION } from './pricing/engine.js';
import { resolveDataDir } from './paths.js';
import { acquireSyncLock, SyncBusyError, LegacyLockError, isSyncBusyError } from './sync-lock.js';

export { SyncBusyError, LegacyLockError, isSyncBusyError };

const TOKEN_FIELDS = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];

/**
 * 执行一次全量发现与增量入库采集。
 *
 * 写入新账本；同一记录重复读到不新增，用量增长更新原行。
 * 以文件为单位入库：一个文件完整解析后在一个事务里写入，解析中途失败的文件一条都不写。
 * 同一来源的文件先全部解析，跨文件出现的同一条事件记录只由一个文件写入（见 settleCopies）。
 * 适配器的第二个参数是该文件的解析计数（坏行、坏字段、零用量）；没有时间的记录在这里丢弃并计 bad_times。
 * 文件解析成功后这些计数并入本次运行的 counts。
 * 受独立 sync-lock.db 事务锁跨进程保护。
 *
 * @param {Object} [options]
 * @param {string} [options.dbPath] 自定义账本路径
 * @param {string} [options.dataDir]
 * @param {boolean} [options.verbose]
 * @returns {Promise<{attempted:number,inserted:number,updated:number,unchanged:number,rejected:number,fileCount:number,durationMs:number,anomalies:string[]}>}
 */
export async function runIngestion(options = {}) {
  const startTime = Date.now();
  const paths = resolveDataDir({ dataDir: options.dataDir, dbPath: options.dbPath });

  // 在打开采集账本与发现日志前获取跨进程锁，持有到本次采集结束
  const lock = acquireSyncLock(paths.dataDir);

  let ledger = null;
  let runId = null;
  try {
    ledger = new Ledger(paths.ledgerPath);
    runId = ledger.write.beginRun();
    const discovered = discoverAll();

    const totals = {
      attempted: 0, inserted: 0, updated: 0, unchanged: 0, rejected: 0, repriced: 0,
      counts: { read_failed: 0, bad_lines: 0, bad_fields: 0, bad_times: 0, zero_usage: 0, cross_file_copies: 0 },
      anomalies: []
    };

    let fileCount = 0;
    for (const [source, files] of Object.entries(discovered)) {
      const parser = adapters[source];
      if (!parser) continue;
      fileCount += files.length;

      const parsed = [];
      for (const file of files) {
        const records = [];
        const notes = newNotes();
        try {
          for await (const record of parser(file, notes)) {
            if (record && typeof record === 'object' && !record.observed_at) {
              note(notes, 'bad_times');
              continue;
            }
            records.push(record);
          }
        } catch (err) {
          if (options.verbose) {
            console.warn(`[WARN] Failed reading ${file} (${source}):`, err.message);
          }
          totals.counts.read_failed += 1;
          totals.anomalies.push(`read_failed: ${source} ${file} — ${err.message}`);
          continue;
        }
        for (const [kind, value] of Object.entries(notes)) totals.counts[kind] = (totals.counts[kind] || 0) + value;
        parsed.push({ file, records });
      }

      const elsewhere = settleCopies(parsed, totals);
      for (const { file, records } of parsed) {
        accumulate(totals, ledger.write.ingestBatch(records, {
          priceOf: costOf, sourceFile: file, parserRev: parserRevOf(source), elsewhere: elsewhere.get(file)
        }));
      }
    }

    // 用量没变但价格版本变了：金额要按当前价表重算
    totals.repriced = ledger.write.reprice(costOf, PRICE_VERSION);

    ledger.write.recordRun(totals.anomalies.length ? 'completed_with_anomalies' : 'ok', totals, runId);

    return {
      ...totals,
      fileCount,
      durationMs: Date.now() - startTime
    };
  } catch (err) {
    // 运行已登记为 running：失败也要收尾，否则界面会一直显示「正在同步」
    if (ledger && runId !== null) {
      try { ledger.write.failRun(runId, err.message); } catch { /* 连接已不可用，下次运行会把它标成 abandoned */ }
    }
    throw err;
  } finally {
    try {
      if (ledger) {
        ledger.close();
      }
    } finally {
      lock.release();
    }
  }
}

/**
 * 同一条事件记录出现在同一来源的多个文件里（例如会话分支或续接时把历史消息复制进新会话）：
 * 只计一次，归开始最早的文件（文件内最早的 observed_at；相同时按路径），会话也就取原始会话。
 * 让出的副本从它所在文件的批次里去掉，它的 replaces 并入保留的那条；
 * 副本的键和 replaces 记进该文件的 elsewhere，写入时不会被当作消失。
 * 累计快照不在此列：同一会话的快照跨文件出现时，旧的不一定是对的。
 *
 * @param {{ file: string, records: Object[] }[]} parsed 会被就地修改
 * @param {Object} totals
 * @returns {Map<string, Set<string>>} 文件 → 归别的文件写入的键
 */
function settleCopies(parsed, totals) {
  const elsewhere = new Map();
  if (parsed.length < 2) return elsewhere;

  const startOf = new Map();
  const holders = new Map();
  for (const { file, records } of parsed) {
    let start = null;
    for (const r of records) {
      if (r?.observed_at && (start === null || r.observed_at < start)) start = r.observed_at;
      if (!r?.record_key || (r.kind || 'event') !== 'event') continue;
      const byFile = holders.get(r.record_key) || new Map();
      if (!byFile.has(file)) byFile.set(file, r);
      holders.set(r.record_key, byFile);
    }
    startOf.set(file, start ?? '');
  }

  const dropped = new Map();
  for (const [key, byFile] of holders) {
    if (byFile.size < 2) continue;
    const [owner, ...copies] = [...byFile.keys()].sort((a, b) =>
      startOf.get(a).localeCompare(startOf.get(b)) || a.localeCompare(b)
    );
    const kept = byFile.get(owner);
    const replaces = new Set(kept.replaces || []);
    for (const file of copies) {
      const copy = byFile.get(file);
      for (const old of copy.replaces || []) replaces.add(old);
      const taken = elsewhere.get(file) || new Set();
      taken.add(key);
      for (const old of copy.replaces || []) taken.add(old);
      elsewhere.set(file, taken);
      (dropped.get(file) || dropped.set(file, new Set()).get(file)).add(key);
      totals.counts.cross_file_copies += 1;
      if (TOKEN_FIELDS.some((f) => (copy[f] ?? null) !== (kept[f] ?? null))) {
        totals.anomalies.push(`cross_file_conflict: ${key} — ${file} 的用量与 ${owner} 不同，按后者计`);
      }
    }
    if (replaces.size) kept.replaces = [...replaces];
  }

  for (const entry of parsed) {
    const keys = dropped.get(entry.file);
    if (keys) entry.records = entry.records.filter((r) => !keys.has(r?.record_key));
  }
  return elsewhere;
}

/**
 * @param {Object} totals
 * @param {Object} stats
 */
function accumulate(totals, stats) {
  totals.attempted += stats.attempted;
  totals.inserted += stats.inserted;
  totals.updated += stats.updated;
  totals.unchanged += stats.unchanged;
  totals.rejected += stats.rejected;
  for (const [key, value] of Object.entries(stats.counts || {})) {
    totals.counts[key] = (totals.counts[key] || 0) + value;
  }
  if (stats.anomalies && stats.anomalies.length) {
    totals.anomalies.push(...stats.anomalies);
  }
}

