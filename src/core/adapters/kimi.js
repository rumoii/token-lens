import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { fileTag, normalizeTimestamp, numberedJsonLines } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 流式解析 Kimi / Kimi Code (月之暗面) 本地会话与转录日志 (*.json, *.jsonl)。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseKimi(filePath, notes) {
  if (!existsSync(filePath)) return;

  const baseName = basename(filePath);
  const defaultSessionId = baseName.replace(/\.[^.]+$/, '') || 'kimi-session';

  // 处理 *.json 整体会话文件
  if (filePath.endsWith('.json')) {
    const content = JSON.parse(readFileSync(filePath, 'utf8'));

    if (!content || typeof content !== 'object') return;

    const items = Array.isArray(content)
      ? content
      : (Array.isArray(content.messages) ? content.messages : (Array.isArray(content.rounds) ? content.rounds : [content]));

    const sessId = String(content.session_id ?? content.sessionId ?? content.id ?? defaultSessionId);

    let ordinal = 0;
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      const role = item.role;
      if (role && role !== 'assistant' && role !== 'model' && role !== 'bot') continue;

      const usage = item.usage || item.token_usage || item;
      const inputTokens = tokenOf(usage, ['prompt_tokens', 'input_tokens', 'input'], notes);
      const outputTokens = tokenOf(usage, ['completion_tokens', 'output_tokens', 'output'], notes);
      const cacheReadTokens = tokenOf(usage, ['cached_tokens', 'cache_read_tokens', 'cacheRead', 'cachedTokens'], notes);
      const cacheCreationTokens = tokenOf(usage, ['cache_write_tokens', 'cacheWrite', 'cache_creation_input_tokens'], notes);

      if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
        note(notes, 'zero_usage');
        continue;
      }

      ordinal += 1;
      const rawModel = item.model ?? content.model;
      const model = rawModel == null ? null : String(rawModel);
      const observedAt = normalizeTimestamp(item.timestamp ?? item.created_at ?? item.time ?? content.created_at ?? content.timestamp);
      const itemId = item.id ?? item.message_id ?? null;

      yield {
        record_key: itemId
          ? `kimi|${sessId}|${itemId}`
          : `kimi|${sessId}|${observedAt}|${ordinal}`,
        source: 'kimi',
        session_id: sessId || null,
        project_key: null,
        model,
        observed_at: observedAt,
        kind: 'event',
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cache_read_tokens: cacheReadTokens,
        cache_write_tokens: cacheCreationTokens,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: cacheCreationTokens
      };
    }
    return;
  }

  // 流式逐行解析 *.jsonl
  const stream = createReadStream(filePath, { encoding: 'utf8' });

  const wireSession = filePath.match(/[\\/]sessions[\\/][^\\/]+[\\/]session_([^\\/]+)[\\/]agents[\\/][^\\/]+[\\/]wire\.jsonl$/i);
  const wireSessionId = wireSession?.[1] || defaultSessionId;
  const wireFileTag = fileTag(filePath);
  let lineNo = 0;
  for await (const [row, physicalLineNo] of numberedJsonLines(stream, notes)) {
    if (!row || typeof row !== 'object') continue;

    if (row.type === 'usage.record') {
      const usage = row.usage;
      if (!usage || typeof usage !== 'object') continue;
      const inputTokens = tokenOf(usage, ['inputOther'], notes);
      const outputTokens = tokenOf(usage, ['output'], notes);
      const cacheReadTokens = tokenOf(usage, ['inputCacheRead'], notes);
      const cacheCreationTokens = tokenOf(usage, ['inputCacheCreation'], notes);
      if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
        note(notes, 'zero_usage');
        continue;
      }
      const observedAt = normalizeTimestamp(row.time);
      yield {
        record_key: `kimi|${wireSessionId}|${wireFileTag}:${observedAt}:${physicalLineNo}`,
        source: 'kimi',
        session_id: wireSessionId,
        project_key: null,
        model: row.model == null ? null : String(row.model),
        observed_at: observedAt,
        kind: 'event',
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cache_read_tokens: cacheReadTokens,
        cache_write_tokens: cacheCreationTokens,
        timestamp: observedAt,
        cache_creation_tokens: cacheCreationTokens
      };
      continue;
    }
    // wire 里只有 usage.record 是一次调用；subagent.completed 等事件带的 usage 是子 agent 的汇总，
    // 子 agent 自己的 wire.jsonl 已逐条记录
    if (wireSession) continue;

    const msg = row.message || row;
    const usage = msg.usage || row.usage || row.token_usage;
    if (!usage || typeof usage !== 'object') continue;

    const role = msg.role || row.role;
    if (role && role !== 'assistant' && role !== 'model' && role !== 'bot') continue;

    const inputTokens = tokenOf(usage, ['prompt_tokens', 'input_tokens', 'input'], notes);
    const outputTokens = tokenOf(usage, ['completion_tokens', 'output_tokens', 'output'], notes);
    const cacheReadTokens = tokenOf(usage, ['cached_tokens', 'cache_read_tokens', 'cacheRead', 'cachedTokens'], notes);
    const cacheCreationTokens = tokenOf(usage, ['cache_write_tokens', 'cacheWrite', 'cache_creation_input_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    lineNo += 1;
    const sessionId = String(row.session_id ?? row.sessionId ?? row.id ?? defaultSessionId);
    const rawModel = msg.model ?? row.model;
    const model = rawModel == null ? null : String(rawModel);
    const observedAt = normalizeTimestamp(row.timestamp ?? row.created_at ?? row.time);
    const rowId = row.id ?? row.message_id ?? null;

    yield {
      record_key: rowId
        ? `kimi|${sessionId}|${rowId}`
        : `kimi|${sessionId}|${observedAt}|${lineNo}`,
      source: 'kimi',
      session_id: sessionId || null,
      project_key: null,
      model,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      cache_read_tokens: cacheReadTokens,
      cache_write_tokens: cacheCreationTokens,
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: cacheCreationTokens
    };
  }
}
