import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp, fileTag } from './_lines.js';
import { isEmptyUsage, note, plus, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

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
 * 从 JSON 结构中安全提取模型名称（兼容 v1 的 modelID 字符串与 v2 的 { id, providerID } 对象）。
 *
 * @param {any} data
 * @returns {string|null}
 */
function extractModelName(data) {
  if (!data || typeof data !== 'object') return null;

  if (typeof data.model === 'string' && data.model) {
    return data.model;
  }
  if (data.model && typeof data.model === 'object') {
    if (typeof data.model.id === 'string' && data.model.id) {
      return data.model.id;
    }
  }
  if (typeof data.modelID === 'string' && data.modelID) {
    return data.modelID;
  }
  return null;
}

/**
 * 流式解析 OpenCode 本地 SQLite 任务数据库（opencode.db）。
 * 采用完全只读安全模式打开，兼容 v2 的 session_message 与 v1 的 message 表。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseOpencodeDb(filePath, notes, source) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    const hasSessionMessage = tableExists(db, 'session_message');
    const hasMessage = tableExists(db, 'message');

    if (!hasSessionMessage && !hasMessage) return;

    let rows = [];
    let sessionTable = 'session_v2';

    // 1. 优先读取 v2 架构的 session_message 表（type === 'assistant'）
    if (hasSessionMessage) {
      const sqlV2 = `
        SELECT id, session_id, time_updated, time_created, data
        FROM session_message
        WHERE type = 'assistant'
        ORDER BY time_updated ASC
      `;
      rows = db.prepare(sqlV2).all() || [];
    }

    // 2. 若 v2 表无数据或不存在，回退读取 v1 架构的 message 表
    if (rows.length === 0 && hasMessage) {
      sessionTable = 'session';
      const sqlV1 = `
        SELECT id, session_id, time_updated, time_created, data
        FROM message
        ORDER BY time_updated ASC
      `;
      rows = db.prepare(sqlV1).all() || [];
    }

    // v2 消息引用 session_v2；v1 消息引用 session，不能跨版本补目录。
    const sessionColumns = new Set(db.prepare(`PRAGMA table_info(${sessionTable})`).all().map(column => column.name));
    const sessionDirectory = sessionColumns.has('id') && sessionColumns.has('directory')
      ? db.prepare(`SELECT directory FROM ${sessionTable} WHERE id = ?`)
      : null;

    for (const [index, row] of rows.entries()) {
      if (!row || typeof row.data !== 'string' || row.data.length === 0) continue;

      let data;
      try {
        data = JSON.parse(row.data);
      } catch {
        note(notes, 'bad_lines');
        continue;
      }

      // 仅处理助手角色
      if (data.type && data.type !== 'assistant' && data.role && data.role !== 'assistant') {
        continue;
      }

      const tokens = data.tokens;
      if (!tokens || typeof tokens !== 'object') continue;

      const inputTokens = tokenOf(tokens, ['input'], notes);
      const outputTokens = plus(tokenOf(tokens, ['output'], notes), tokenOf(tokens, ['reasoning'], notes));

      const cache = tokens.cache || {};
      const cacheRead = tokenOf(cache, ['read'], notes);
      const cacheWrite = tokenOf(cache, ['write'], notes);

      if (isEmptyUsage(inputTokens, outputTokens, cacheRead, cacheWrite)) {
        note(notes, 'zero_usage');
        continue;
      }

      const sessionId = String(row.session_id || data.sessionID || data.session_id || '');
      const model = extractModelName(data);
      const provider = data.model?.providerID ?? data.providerID;
      const rawTimestamp = row.time_updated || row.time_created || data.time?.completed || data.time?.created;
      const observedAt = normalizeTimestamp(rawTimestamp);
      const messageId = row.id ?? data.id ?? null;

      yield {
        record_key: messageId
          ? `${source}|${sessionId}|${messageId}`
          : `${source}|${sessionId}|${fileTag(filePath)}|${observedAt}|${index}`,
        ...(!messageId ? { replaces: [`${source}|${sessionId}|${observedAt}`] } : {}),
        source,
        session_id: sessionId || null,
        project_key: projectFromCwd(sessionDirectory?.get(sessionId)?.directory),
        model,
        provider: typeof provider === 'string' && provider.trim() ? provider : null,
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
  } finally {
    if (db) {
      try {
        db.close();
      } catch {}
    }
  }
}

export async function* parseOpencode(filePath, notes) {
  yield* parseOpencodeDb(filePath, notes, 'opencode');
}
