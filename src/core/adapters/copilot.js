import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { basename, dirname, join } from 'node:path';
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
 * 读取表的列名集合，用于在缺失列时降级而不是崩溃。
 *
 * @param {DatabaseSync} db
 * @param {string} tableName
 * @returns {Set<string>}
 */
function getColumns(db, tableName) {
  try {
    const rows = db.prepare(`PRAGMA table_info(${tableName})`).all();
    return new Set(rows.map((r) => r.name));
  } catch {
    return new Set();
  }
}

/**
 * 流式解析 GitHub Copilot 本地 SQLite 数据库（session-store.db 或 data.db）。
 * 采用完全只读安全模式打开，兼容 assistant_usage_events 事件表与 sessions 会话表。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseCopilot(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    const hasEvents = tableExists(db, 'assistant_usage_events');
    const hasSessions = tableExists(db, 'sessions');

    if (!hasEvents && !hasSessions) return;
    const detailedSessions = new Set();
    // 两库仍都发现：按会话取舍，data.db 中独有的会话不能丢。
    const sibling = join(dirname(filePath), 'session-store.db');
    if (basename(filePath) === 'data.db' && existsSync(sibling)) {
      for await (const record of parseCopilot(sibling)) {
        if (record.kind === 'event' && record.observed_at) detailedSessions.add(record.session_id);
      }
    }

    // 1. 优先读取 session-store.db 中的 assistant_usage_events 明细表
    if (hasEvents) {
      // 有行 id 就用行 id 作身份；没有时只能用时间 + 序号
      const eventCols = getColumns(db, 'assistant_usage_events');
      const idCol = eventCols.has('id') ? 'id' : 'NULL AS id';

      const sql = `
        SELECT
          ${idCol},
          session_id,
          model,
          input_tokens,
          output_tokens,
          cache_read_tokens,
          cache_write_tokens,
          reasoning_tokens,
          created_at
        FROM assistant_usage_events
        ORDER BY created_at ASC
      `;

      const rows = db.prepare(sql).all() || [];

      let ordinal = 0;

      for (const row of rows) {
        const inputTokens = tokenOf(row, ['input_tokens'], notes);
        const outputTokens = plus(tokenOf(row, ['output_tokens'], notes), tokenOf(row, ['reasoning_tokens'], notes));
        const cacheRead = tokenOf(row, ['cache_read_tokens'], notes);
        const cacheWrite = tokenOf(row, ['cache_write_tokens'], notes);

        if (isEmptyUsage(inputTokens, outputTokens, cacheRead, cacheWrite)) {
          note(notes, 'zero_usage');
          continue;
        }

        ordinal += 1;
        const sessionId = String(row.session_id || 'copilot-session');
        const observedAt = normalizeTimestamp(row.created_at);
        if (observedAt) detailedSessions.add(sessionId);

        yield {
          record_key: row.id !== null && row.id !== undefined
            ? `copilot|${sessionId}|${row.id}`
            : `copilot|${sessionId}|${observedAt}|${ordinal}`,
          replaces: [`copilot|${sessionId}`],
          source: 'copilot',
          session_id: sessionId,
          project_key: null,
          model: row.model ? String(row.model) : null,
          observed_at: observedAt,
          kind: 'event',
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          cache_read_tokens: cacheRead,
          cache_write_tokens: cacheWrite,
          // 兼容别名：Phase 1 收尾时随旧 store 一起删除
          timestamp: observedAt,
          cache_creation_tokens: cacheWrite
        };
      }
    }

    // 2. 回退读取 data.db 中的 sessions 汇总表
    if (hasSessions) {
      const sql = `
        SELECT
          id,
          model,
          total_input_tokens,
          total_output_tokens,
          total_cached_tokens,
          total_reasoning_tokens,
          coalesce(updated_at, created_at) AS event_time
        FROM sessions
        ORDER BY event_time ASC
      `;

      const rows = db.prepare(sql).all() || [];

      for (const row of rows) {
        const inputTokens = tokenOf(row, ['total_input_tokens'], notes);
        const outputTokens = plus(tokenOf(row, ['total_output_tokens'], notes), tokenOf(row, ['total_reasoning_tokens'], notes));
        const cacheRead = tokenOf(row, ['total_cached_tokens'], notes);

        if (isEmptyUsage(inputTokens, outputTokens, cacheRead, null)) {
          note(notes, 'zero_usage');
          continue;
        }

        const sessionId = String(row.id || 'copilot-app-session');
        if (detailedSessions.has(sessionId)) continue;
        const observedAt = normalizeTimestamp(row.event_time);

        yield {
          // sessions 表是整场会话的累计值
          record_key: `copilot|${sessionId}`,
          source: 'copilot',
          session_id: sessionId,
          project_key: null,
          model: row.model ? String(row.model) : null,
          observed_at: observedAt,
          kind: 'cumulative',
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          cache_read_tokens: cacheRead,
          cache_write_tokens: null,
          // 兼容别名：Phase 1 收尾时随旧 store 一起删除
          timestamp: observedAt,
          cache_creation_tokens: null
        };
      }
    }
  } finally {
    if (db) {
      try {
        db.close();
      } catch {}
    }
  }
}
