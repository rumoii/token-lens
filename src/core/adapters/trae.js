import { readFile } from 'node:fs/promises';
import { createReadStream, existsSync } from 'node:fs';
import { extname, basename } from 'node:path';
import { jsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { isEmptyUsage, minus, note, tokenOf } from './_num.js';

/**
 * 从会话条目中提取规范用量。
 */
function extractTraeUsage(item, notes) {
  const direct = item.extra_info || item;

  let input = tokenOf(direct, ['input_token', 'inputTokens', 'input'], notes);
  const output = tokenOf(direct, ['output_token', 'outputTokens', 'output'], notes);
  const cacheRead = tokenOf(direct, ['cache_read_token', 'cachedTokens', 'cached_tokens'], notes);
  const cacheWrite = tokenOf(direct, ['cache_write_token', 'cacheWriteTokens'], notes);

  if (isEmptyUsage(input, output, cacheRead, cacheWrite)) {
    note(notes, 'zero_usage');
    return null;
  }

  // 若 input 中包含了缓存读取，则扣除计算纯未缓存输入
  if (cacheRead !== null && input !== null && cacheRead > 0 && input >= cacheRead) {
    input = minus(input, cacheRead);
  }

  return { input, output, cacheRead, cacheWrite };
}

/**
 * 流式解析 Trae / Trae CN 的本地会话或用量快照文件（*.json 或 *.jsonl）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseTrae(filePath, notes) {
  if (!existsSync(filePath)) return;

  const ext = extname(filePath).toLowerCase();
  const fileSessionId = basename(filePath, ext);

  if (ext === '.jsonl') {
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    let ordinal = 0;
    for await (const row of jsonLines(stream, notes)) {
      if (!row || typeof row !== 'object') continue;

      const usage = extractTraeUsage(row, notes);
      if (!usage) continue;

      ordinal += 1;
      const sessionId = String(row.session_id ?? row.id ?? fileSessionId);
      const rawModel = row.model_name ?? row.model;
      const model = rawModel == null ? null : String(rawModel);
      const observedAt = normalizeTimestamp(row.usage_time ?? row.timestamp);
      const rowId = row.message_id ?? null;

      yield {
        record_key: rowId
          ? `trae|${sessionId}|${rowId}`
          : `trae|${sessionId}|${observedAt}|${ordinal}`,
        source: 'trae',
        session_id: sessionId || null,
        project_key: null,
        model,
        observed_at: observedAt,
        kind: 'event',
        input_tokens: usage.input,
        output_tokens: usage.output,
        cache_read_tokens: usage.cacheRead,
        cache_write_tokens: usage.cacheWrite,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: usage.cacheWrite
      };
    }
  } else {
    // .json 文件（可能是 sessions 数组或单个 session 对象）
    const content = await readFile(filePath, 'utf8');
    const parsed = JSON.parse(content);

    if (!parsed || typeof parsed !== 'object') return;

    const list = Array.isArray(parsed)
      ? parsed
      : Array.isArray(parsed.sessions)
        ? parsed.sessions
        : [parsed];

    let ordinal = 0;
    for (const [index, item] of list.entries()) {
      if (!item || typeof item !== 'object') continue;

      const usage = extractTraeUsage(item, notes);
      if (!usage) continue;

      ordinal += 1;
      const hasSessionId = item.session_id !== undefined && item.session_id !== null;
      const sessionId = String(item.session_id ?? item.id ?? fileSessionId);
      const rawModel = item.model_name ?? item.model;
      const model = rawModel == null ? null : String(rawModel);
      const observedAt = normalizeTimestamp(item.usage_time ?? item.timestamp);

      yield {
        // 累计快照仍按条目覆盖；同会话的多个条目不能共用一个键。
        record_key: `trae|${sessionId}|${fileTag(filePath)}:${index}`,
        replaces: [hasSessionId
          ? `trae|${sessionId}`
          : `trae|${sessionId}|${observedAt}|${ordinal}`],
        source: 'trae',
        session_id: sessionId || null,
        project_key: null,
        model,
        observed_at: observedAt,
        kind: hasSessionId ? 'cumulative' : 'event',
        input_tokens: usage.input,
        output_tokens: usage.output,
        cache_read_tokens: usage.cacheRead,
        cache_write_tokens: usage.cacheWrite,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: usage.cacheWrite
      };
    }
  }
}
