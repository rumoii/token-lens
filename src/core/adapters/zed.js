import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { decompressZstdText } from './_zstd.js';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, plus, tokenOf } from './_num.js';

/**
 * 检查数据库中是否存在指定表。
 *
 * @param {DatabaseSync} db
 * @param {string} tableName
 * @returns {boolean}
 */
function tableExists(db, tableName) {
  const row = db.prepare(
    `SELECT count(*) AS cnt FROM sqlite_master WHERE type='table' AND name=?`
  ).get(tableName);
  return Boolean(row && row.cnt > 0);
}

/**
 * 解码 Zed threads 表中的 BLOB 数据载荷（支持 raw JSON 与 zstd 压缩）。
 *
 * @param {string} dataType
 * @param {Buffer|Uint8Array} dataBlob
 * @returns {Promise<string|null>}
 */
async function decodeThreadPayload(dataType, dataBlob, notes) {
  if (!dataBlob || dataBlob.length === 0) return null;

  try {
    const buf = Buffer.isBuffer(dataBlob) ? dataBlob : Buffer.from(dataBlob);
    if (dataType === 'zstd') {
      return decompressZstdText(buf);
    }
    // 默认或 json 类型
    return buf.toString('utf8');
  } catch {
    note(notes, 'bad_lines');
    return null;
  }
}

/**
 * 从解析后的 thread 对象中提取用量与模型。
 * 优先累加 request_token_usage 各轮明细，回退累加 cumulative_token_usage。
 *
 * @param {any} thread
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number, model: string|null }|null}
 */
function extractThreadUsage(thread, notes) {
  if (!thread || typeof thread !== 'object') return null;
  // 跳过外部导入会话
  if (thread.imported === true) return null;

  let model = null;
  if (typeof thread.model === 'string' && thread.model) {
    model = thread.model;
  } else if (thread.model && typeof thread.model === 'object') {
    if (typeof thread.model.model === 'string' && thread.model.model) {
      model = thread.model.model;
    }
  }

  let input = null;
  let output = null;
  let cacheRead = null;
  let cacheWrite = null;

  // 1. 优先使用 request_token_usage 逐轮累加
  const reqUsage = thread.request_token_usage;
  if (reqUsage && typeof reqUsage === 'object') {
    const rounds = Object.values(reqUsage);
    for (const r of rounds) {
      if (!r || typeof r !== 'object') continue;
      input = plus(input, tokenOf(r, ['input_tokens'], notes));
      output = plus(output, tokenOf(r, ['output_tokens'], notes));
      cacheRead = plus(cacheRead, tokenOf(r, ['cache_read_input_tokens', 'cached_input_tokens'], notes));
      cacheWrite = plus(cacheWrite, tokenOf(r, ['cache_creation_input_tokens'], notes));
    }
  }

  // 2. 若 request_token_usage 为空，回退 cumulative_token_usage
  if (isEmptyUsage(input, output, cacheRead, cacheWrite)) {
    const cum = thread.cumulative_token_usage;
    if (cum && typeof cum === 'object') {
      input = tokenOf(cum, ['input_tokens'], notes);
      output = tokenOf(cum, ['output_tokens'], notes);
      cacheRead = tokenOf(cum, ['cache_read_input_tokens', 'cached_input_tokens'], notes);
      cacheWrite = tokenOf(cum, ['cache_creation_input_tokens'], notes);
    }
  }

  if (isEmptyUsage(input, output, cacheRead, cacheWrite)) {
    note(notes, 'zero_usage');
    return null;
  }

  return { input, output, cacheRead, cacheWrite, model };
}

/**
 * 流式解析 Zed Editor 本地 AI 线程数据库（threads.db）。
 * 采用完全只读安全模式打开，兼容 raw JSON 与 zstd 压缩载荷。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseZed(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    if (!tableExists(db, 'threads')) return;

    const sql = `
      SELECT id, updated_at, data_type, data
      FROM threads
      ORDER BY updated_at ASC
    `;

    const rows = db.prepare(sql).all() || [];

    for (const row of rows) {
      const jsonText = await decodeThreadPayload(row.data_type, row.data, notes);
      if (!jsonText) continue;

      let thread;
      try {
        thread = JSON.parse(jsonText);
      } catch {
        note(notes, 'bad_lines');
        continue;
      }

      const usage = extractThreadUsage(thread, notes);
      if (!usage) continue;

      const sessionId = String(row.id || thread.id || 'zed-thread');
      const rawTimestamp = thread.updated_at || row.updated_at;
      const observedAt = normalizeTimestamp(rawTimestamp);

      yield {
        // 线程级汇总：整条线程只有一个有效版本
        record_key: `zed|${sessionId}`,
        source: 'zed',
        session_id: sessionId || null,
        project_key: null,
        model: usage.model,
        observed_at: observedAt,
        kind: 'cumulative',
        input_tokens: usage.input,
        output_tokens: usage.output,
        cache_read_tokens: usage.cacheRead,
        cache_write_tokens: usage.cacheWrite,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: usage.cacheWrite
      };
    }
  } finally {
    if (db) {
      try {
        db.close();
      } catch {}
    }
  }
}
