import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 动态获取目标表的所有可用列集合。
 *
 * @param {DatabaseSync} db
 * @param {string} tableName
 * @returns {Set<string>}
 */
function getTableColumns(db, tableName) {
  const rows = db.prepare(`PRAGMA table_info(${tableName})`).all();
  return new Set(rows.map((r) => r.name));
}

/**
 * 流式解析 Hermes Agent 状态数据库（state.db）。
 * 采用完全只读安全模式打开，防止干扰正在进行的 WAL 写入与检查点合并。
 * 动态适配列名，保证在各版本/精简表结构下均不崩溃。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseHermes(filePath, notes) {
  if (!existsSync(filePath)) {
    return;
  }

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    const usageCols = getTableColumns(db, 'session_model_usage');
    const sessionCols = getTableColumns(db, 'sessions');

    let rows = [];

    // 1. 优先使用模型细粒度表 session_model_usage
    if (usageCols.size > 0) {
      const timeCol = usageCols.has('last_seen')
        ? 'last_seen'
        : usageCols.has('first_seen')
          ? 'first_seen'
          : 'NULL';
      const cacheWriteCol = usageCols.has('cache_write_tokens') ? 'cache_write_tokens' : 'NULL';
      const cacheReadCol = usageCols.has('cache_read_tokens') ? 'cache_read_tokens' : 'NULL';

      const sql = `
        SELECT
          session_id,
          model,
          input_tokens,
          output_tokens,
          ${cacheReadCol} AS cache_read_tokens,
          ${cacheWriteCol} AS cache_write_tokens,
          ${timeCol} AS event_time
        FROM session_model_usage
        ORDER BY ${timeCol} DESC
      `;
      rows = db.prepare(sql).all() || [];
    }

    // 2. 若 session_model_usage 为空，回退读取 sessions 表的用量汇总
    if (rows.length === 0 && sessionCols.size > 0) {
      const timeCol = sessionCols.has('last_activity_at')
        ? 'last_activity_at'
        : sessionCols.has('started_at')
          ? 'started_at'
          : 'NULL';
      const cacheWriteCol = sessionCols.has('cache_write_tokens') ? 'cache_write_tokens' : 'NULL';
      const cacheReadCol = sessionCols.has('cache_read_tokens') ? 'cache_read_tokens' : 'NULL';

      const sql = `
        SELECT
          id AS session_id,
          model,
          input_tokens,
          output_tokens,
          ${cacheReadCol} AS cache_read_tokens,
          ${cacheWriteCol} AS cache_write_tokens,
          ${timeCol} AS event_time
        FROM sessions
        WHERE (input_tokens > 0 OR output_tokens > 0 OR ${cacheReadCol} > 0 OR ${cacheWriteCol} > 0)
        ORDER BY ${timeCol} DESC
      `;
      rows = db.prepare(sql).all() || [];
    }

    for (const row of rows) {
      const inputTokens = tokenOf(row, ['input_tokens'], notes);
      const outputTokens = tokenOf(row, ['output_tokens'], notes);
      const cacheReadTokens = tokenOf(row, ['cache_read_tokens'], notes);
      const cacheCreationTokens = tokenOf(row, ['cache_write_tokens'], notes);

      if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
        note(notes, 'zero_usage');
        continue;
      }

      const sessionId = String(row.session_id || '');
      const model = row.model ? String(row.model) : null;
      const observedAt = normalizeTimestamp(row.event_time);

      yield {
        // 同一会话同一模型只保留当前快照；缺模型保留旧键占位，model 仍为 NULL。
        record_key: `hermes|${sessionId}|${model ?? 'hermes-agent'}`,
        source: 'hermes',
        session_id: sessionId || null,
        project_key: null,
        model,
        observed_at: observedAt,
        kind: 'cumulative',
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cache_read_tokens: cacheReadTokens,
        cache_write_tokens: cacheCreationTokens,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: cacheCreationTokens
      };
    }
  } finally {
    // 关键：必须显式关闭以立即释放 WAL 共享读锁，允许 Hermes 宿主自由执行 checkpoint
    if (db) {
      try {
        db.close();
      } catch {}
    }
  }
}
