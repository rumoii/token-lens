import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { extname, basename } from 'node:path';
import { normalizeTimestamp, fileTag } from './_lines.js';
import { isEmptyUsage, note, plus, toToken } from './_num.js';

function toInt(val, notes) {
  if (typeof val === 'string') return toToken(val.replace(/[$,\s]/g, ''), notes);
  return toToken(val, notes);
}

/**
 * RFC 4180 状态机零正则 CSV 行解析器。
 */
function parseCsvRow(text, startIndex) {
  const cells = [];
  let cell = '';
  let i = startIndex;
  const len = text.length;

  const FIELD_START = 0;
  const IN_QUOTED = 1;
  const IN_UNQUOTED = 2;
  const AFTER_QUOTE = 3;

  let state = FIELD_START;

  while (i < len) {
    const ch = text[i];

    switch (state) {
      case FIELD_START:
        if (ch === '"') {
          state = IN_QUOTED;
          i++;
        } else if (ch === ',') {
          cells.push(cell);
          cell = '';
          i++;
        } else if (ch === '\n' || ch === '\r') {
          cells.push(cell);
          if (ch === '\r' && i + 1 < len && text[i + 1] === '\n') {
            i += 2;
          } else {
            i++;
          }
          return { cells, nextIndex: i };
        } else {
          cell += ch;
          state = IN_UNQUOTED;
          i++;
        }
        break;

      case IN_QUOTED:
        if (ch === '"') {
          state = AFTER_QUOTE;
          i++;
        } else {
          cell += ch;
          i++;
        }
        break;

      case AFTER_QUOTE:
        if (ch === '"') {
          cell += '"';
          state = IN_QUOTED;
          i++;
        } else if (ch === ',') {
          cells.push(cell);
          cell = '';
          state = FIELD_START;
          i++;
        } else if (ch === '\n' || ch === '\r') {
          cells.push(cell);
          if (ch === '\r' && i + 1 < len && text[i + 1] === '\n') {
            i += 2;
          } else {
            i++;
          }
          return { cells, nextIndex: i };
        } else {
          cell += ch;
          state = IN_UNQUOTED;
          i++;
        }
        break;

      case IN_UNQUOTED:
        if (ch === ',') {
          cells.push(cell);
          cell = '';
          state = FIELD_START;
          i++;
        } else if (ch === '\n' || ch === '\r') {
          cells.push(cell);
          if (ch === '\r' && i + 1 < len && text[i + 1] === '\n') {
            i += 2;
          } else {
            i++;
          }
          return { cells, nextIndex: i };
        } else {
          cell += ch;
          i++;
        }
        break;
    }
  }

  cells.push(cell);
  return { cells, nextIndex: i };
}

/**
 * 通道 A：解析 Cursor 官方导出的 CSV 账本。
 */
async function* parseCursorCsv(filePath, notes) {
  const text = await readFile(filePath, 'utf8');
  if (!text || text.length === 0) return;

  const headerResult = parseCsvRow(text, 0);
  const headerCols = headerResult.cells.map(c => c.trim().toLowerCase());
  let cursor = headerResult.nextIndex;

  const dateIdx = headerCols.findIndex(c => c === 'date');
  const modelIdx = headerCols.findIndex(c => c === 'model');
  const inputWithCacheIdx = headerCols.findIndex(c => c.includes('w/ cache write'));
  const inputNoCacheIdx = headerCols.findIndex(c => c.includes('w/o cache write') || c.includes('input tokens'));
  const cacheReadIdx = headerCols.findIndex(c => c.includes('cache read'));
  const outputIdx = headerCols.findIndex(c => c.includes('output tokens'));

  if (dateIdx === -1 || modelIdx === -1) {
    return; // 非标准 Cursor 账本表头
  }

  const sessionPrefix = basename(filePath, '.csv');
  let ordinal = 0;

  while (cursor < text.length) {
    if (text[cursor] === '\n' || text[cursor] === '\r') {
      cursor++;
      continue;
    }

    const { cells, nextIndex } = parseCsvRow(text, cursor);
    cursor = nextIndex;

    if (cells.length < 2) continue;

    const rawDate = cells[dateIdx]?.trim();
    if (!rawDate) continue;

    const model = cells[modelIdx]?.trim() || null;
    const inputWithCache = inputWithCacheIdx >= 0 ? toInt(cells[inputWithCacheIdx], notes) : null;
    const inputNoCache = inputNoCacheIdx >= 0 ? toInt(cells[inputNoCacheIdx], notes) : null;
    const cacheRead = cacheReadIdx >= 0 ? toInt(cells[cacheReadIdx], notes) : null;
    const output = outputIdx >= 0 ? toInt(cells[outputIdx], notes) : null;
    const cacheWrite = inputWithCache !== null && inputNoCache !== null
      ? Math.max(0, inputWithCache - inputNoCache)
      : null;

    if (isEmptyUsage(inputNoCache, output, cacheRead, cacheWrite)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const observedAt = normalizeTimestamp(rawDate);

    yield {
      record_key: `cursor|${fileTag(filePath)}|${observedAt}|${ordinal}`,
      replaces: [`cursor|${sessionPrefix}|${observedAt}|${ordinal}`],
      source: 'cursor',
      session_id: sessionPrefix || null,
      project_key: null,
      model,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: inputNoCache,
      output_tokens: output,
      cache_read_tokens: cacheRead,
      cache_write_tokens: cacheWrite,
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: cacheWrite
    };
  }
}

/**
 * 通道 B：解析 Cursor 本地状态数据库 state.vscdb。
 */
async function* parseCursorVscdb(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');

    const tableCheck = db.prepare(
      `SELECT count(*) as c FROM sqlite_master WHERE type='table' AND name='ItemTable'`
    ).get();

    if (!tableCheck || tableCheck.c === 0) return;

    const targetKeys = ['composerData', 'workbench.panel.aichat.view.aichat.chatdata'];
    const rows = db.prepare(
      `SELECT key, value FROM ItemTable WHERE key IN (?, ?)`
    ).all(...targetKeys);

    for (const row of rows) {
      if (!row || typeof row.value !== 'string' || row.value.length === 0) continue;

      let parsed;
      try {
        parsed = JSON.parse(row.value);
      } catch {
        note(notes, 'bad_lines');
        continue;
      }

      if (row.key === 'composerData') {
        const root = parsed?.composerData ?? parsed;
        const entries = Array.isArray(root) ? root : Object.values(root || {});

        for (const [index, item] of entries.entries()) {
          if (!item || typeof item !== 'object') continue;
          const msgs = item.conversation ?? item.messages ?? item.tabs ?? [];
          if (!Array.isArray(msgs)) continue;

          let promptTokens = null;
          let completionTokens = null;
          const model = item.model || item.modelId ? String(item.model || item.modelId) : null;
          let timestampRaw = item.createdAt ?? item.lastSendTime ?? item.timestamp;

          for (const msg of msgs) {
            if (!msg || typeof msg !== 'object') continue;
            const t = toInt(msg.tokenCount ?? msg.tokens ?? msg.usage?.total_tokens, notes);
            const isUser = msg.type === 1 || msg.role === 'user' || msg.isUser === true;
            if (isUser) promptTokens = plus(promptTokens, t);
            else completionTokens = plus(completionTokens, t);
          }

          if (isEmptyUsage(promptTokens, completionTokens, null, null)) {
            note(notes, 'zero_usage');
            continue;
          }

          const composerId = String(item.id ?? item.composerId ?? 'composer-session');
          const hasId = item.id !== undefined && item.id !== null || item.composerId !== undefined && item.composerId !== null;
          const observedAt = normalizeTimestamp(timestampRaw);

          yield {
            // composer 条目内的多轮已汇总，按条目保留一个有效版本
            record_key: hasId ? `cursor|${composerId}` : `cursor|${fileTag(filePath)}|composer:${index}`,
            ...(!hasId ? { replaces: [`cursor|${composerId}`] } : {}),
            source: 'cursor',
            session_id: composerId,
            project_key: null,
            model,
            observed_at: observedAt,
            kind: 'cumulative',
            input_tokens: promptTokens,
            output_tokens: completionTokens,
            cache_read_tokens: null,
            cache_write_tokens: null,
            // 兼容别名：Phase 1 收尾时随旧 store 一起删除
            timestamp: observedAt,
            cache_creation_tokens: null
          };
        }
      } else {
        // workbench.panel.aichat.view.aichat.chatdata
        const tabs = Array.isArray(parsed?.tabs) ? parsed.tabs : Array.isArray(parsed) ? parsed : Object.values(parsed || {});
        for (const [index, tab] of tabs.entries()) {
          if (!tab || typeof tab !== 'object') continue;
          const msgs = tab.chatMessages ?? tab.messages ?? tab.conversation ?? [];
          if (!Array.isArray(msgs)) continue;

          let promptTokens = null;
          let completionTokens = null;
          const model = tab.model || tab.modelId ? String(tab.model || tab.modelId) : null;
          let timestampRaw = tab.createdAt ?? tab.lastSendTime ?? tab.timestamp;

          for (const msg of msgs) {
            if (!msg || typeof msg !== 'object') continue;
            const t = toInt(msg.tokenCount ?? msg.tokens ?? msg.usage?.total_tokens, notes);
            const isUser = msg.role === 'user' || msg.type === 1 || msg.isUser === true;
            if (isUser) promptTokens = plus(promptTokens, t);
            else completionTokens = plus(completionTokens, t);
          }

          if (isEmptyUsage(promptTokens, completionTokens, null, null)) {
            note(notes, 'zero_usage');
            continue;
          }

          const tabId = String(tab.id ?? tab.tabId ?? 'chat-session');
          const hasId = tab.id !== undefined && tab.id !== null || tab.tabId !== undefined && tab.tabId !== null;
          const observedAt = normalizeTimestamp(timestampRaw);

          yield {
            // 单个 tab 内多轮已汇总，按 tab 保留一个有效版本
            record_key: hasId ? `cursor|${tabId}` : `cursor|${fileTag(filePath)}|chat:${index}`,
            ...(!hasId ? { replaces: [`cursor|${tabId}`] } : {}),
            source: 'cursor',
            session_id: tabId,
            project_key: null,
            model,
            observed_at: observedAt,
            kind: 'cumulative',
            input_tokens: promptTokens,
            output_tokens: completionTokens,
            cache_read_tokens: null,
            cache_write_tokens: null,
            // 兼容别名：Phase 1 收尾时随旧 store 一起删除
            timestamp: observedAt,
            cache_creation_tokens: null
          };
        }
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

/**
 * 流式解析 Cursor 会话记录（双通道分流：CSV 或 state.vscdb）。
 *
 * @param {string} filePath
 * @yields {Object} 统一用量记录
 */
export async function* parseCursor(filePath, notes) {
  const ext = extname(filePath).toLowerCase();
  if (ext === '.csv') {
    yield* parseCursorCsv(filePath, notes);
  } else if (ext === '.vscdb' || ext === '.sqlite' || ext === '.db') {
    yield* parseCursorVscdb(filePath, notes);
  }
}
