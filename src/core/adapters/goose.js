import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, toToken } from './_num.js';

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
 * 动态获取目标表字段名集合。
 *
 * @param {DatabaseSync} db
 * @param {string} tableName
 * @returns {Set<string>}
 */
function getTableColumns(db, tableName) {
  try {
    const rows = db.prepare(`PRAGMA table_info(${tableName})`).all();
    return new Set(rows.map(r => r.name));
  } catch {
    return new Set();
  }
}

/**
 * 从 model_config_json 文本中提取模型名称。
 *
 * @param {string} configJson
 * @returns {string|null}
 */
function extractModelName(configJson) {
  if (!configJson || typeof configJson !== 'string') return null;
  try {
    const obj = JSON.parse(configJson);
    const m = obj?.model_name || obj?.model || obj?.modelId;
    return m ? String(m).trim() : null;
  } catch {
    return null;
  }
}

/**
 * 流式解析 Block Goose 本地任务数据库（sessions.db / data.db）。
 * 采用完全只读安全模式打开，优先读取 accumulated 累计 Token，并兼容旧表结构。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseGoose(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    const hasSessions = tableExists(db, 'sessions');
    if (!hasSessions) return;

    const cols = getTableColumns(db, 'sessions');

    const hasAcc = cols.has('accumulated_input_tokens');
    const inputCol = hasAcc ? 'coalesce(accumulated_input_tokens, input_tokens)' : 'input_tokens';
    const outputCol = hasAcc ? 'coalesce(accumulated_output_tokens, output_tokens)' : 'output_tokens';
    const totalCol = hasAcc ? 'coalesce(accumulated_total_tokens, total_tokens)' : 'total_tokens';

    const sql = `
      SELECT
        id,
        model_config_json,
        provider_name,
        created_at,
        ${inputCol} AS input_tokens,
        ${outputCol} AS output_tokens,
        ${totalCol} AS total_tokens
      FROM sessions
      ORDER BY created_at ASC
    `;

    const rows = db.prepare(sql).all() || [];

    for (const row of rows) {
      const inputTokens = toToken(row.input_tokens, notes);
      const outputTokens = toToken(row.output_tokens, notes);
      // total 的余量没有可确认的分类，不当作输出或缓存入账。
      if (isEmptyUsage(inputTokens, outputTokens, null, null)) {
        note(notes, 'zero_usage');
        continue;
      }

      const sessionId = String(row.id || 'goose-session');
      const model = extractModelName(row.model_config_json);
      const observedAt = normalizeTimestamp(row.created_at);

      yield {
        // 表里是 accumulated 累计值：一个会话只有一个有效版本
        record_key: `goose|${sessionId}`,
        source: 'goose',
        session_id: sessionId || null,
        project_key: null,
        model,
        provider: typeof row.provider_name === 'string' && row.provider_name.trim() ? row.provider_name : null,
        observed_at: observedAt,
        kind: 'cumulative',
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cache_read_tokens: null,
        cache_write_tokens: null,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: null
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
