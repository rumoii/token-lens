import { createReadStream, existsSync } from 'node:fs';
import { basename } from 'node:path';
import { createHash } from 'node:crypto';
import { jsonLines, normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 流式解析 OpenClaw 本地 Agent 会话日志（*.jsonl*）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseOpenclaw(filePath, notes) {
  if (!existsSync(filePath)) return;

  const baseName = basename(filePath);
  const defaultSessionId = baseName.split('.')[0] || 'openclaw-session';
  const stream = createReadStream(filePath, { encoding: 'utf8' });
  let ordinal = 0;

  for await (const row of jsonLines(stream, notes)) {
    if (!row || typeof row !== 'object') continue;

    // 支持顶层 usage 或嵌套 message.usage
    const msg = row.message || row;
    const usage = msg.usage || row.usage;
    if (!usage || typeof usage !== 'object') continue;

    const role = msg.role || row.role;
    if (role && role !== 'assistant' && role !== 'model') continue;

    const inputTokens = tokenOf(usage, ['input', 'prompt_tokens', 'input_tokens'], notes);
    const outputTokens = tokenOf(usage, ['output', 'completion_tokens', 'output_tokens'], notes);
    const cacheReadTokens = tokenOf(usage, ['cacheRead', 'cache_read_tokens', 'cachedTokens'], notes);
    const cacheCreationTokens = tokenOf(usage, ['cacheWrite', 'cache_write_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const sessionId = String(row.session_id ?? row.sessionId ?? row.id ?? defaultSessionId);
    const rawModel = msg.model ?? row.model;
    const model = rawModel == null ? null : String(rawModel);
    const observedAt = normalizeTimestamp(row.timestamp ?? row.created_at ?? row.time);
    // 内容身份不含用量、文件位置或会话名；归档副本即使序号变化也取同一键。
    const identity = createHash('sha256').update(JSON.stringify([
      observedAt, row.id ?? null, msg.id ?? null, role ?? null,
      msg.content ?? msg.text ?? row.content ?? null, msg.tool_calls ?? null
    ])).digest('hex');

    yield {
      record_key: `openclaw|c${identity}`,
      replaces: [`openclaw|${sessionId}|${observedAt}|${ordinal}`],
      source: 'openclaw',
      session_id: sessionId || null,
      project_key: null,
      model,
      provider: typeof msg.provider === 'string' && msg.provider.trim() ? msg.provider : null,
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
