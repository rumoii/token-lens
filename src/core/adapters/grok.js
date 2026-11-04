import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { jsonLines, normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 流式解析 xAI Grok Build CLI 会话日志（updates.jsonl）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseGrok(filePath, notes) {
  let sessionModel = null;
  const sessionDir = dirname(filePath);
  const summaryPath = join(sessionDir, 'summary.json');

  if (existsSync(summaryPath)) {
    try {
      const summary = JSON.parse(readFileSync(summaryPath, 'utf8'));
      if (summary?.current_model_id) {
        sessionModel = String(summary.current_model_id);
      }
    } catch {
      note(notes, 'bad_lines');
    }
  }

  const stream = createReadStream(filePath, { encoding: 'utf8' });
  let ordinal = 0;

  for await (const obj of jsonLines(stream, notes)) {
    const params = obj?.params;
    const update = params?.update;
    if (!update || update.sessionUpdate !== 'turn_completed') {
      continue;
    }

    const usage = update.usage;
    if (!usage) continue;

    const inputTokens = tokenOf(usage, ['inputTokens', 'input_tokens'], notes);
    const outputTokens = tokenOf(usage, ['outputTokens', 'output_tokens'], notes);
    const cacheReadTokens = tokenOf(usage, ['cachedReadTokens', 'cacheReadInputTokens', 'cache_read_input_tokens'], notes);
    const cacheCreationTokens = tokenOf(usage, ['cachedWriteTokens', 'cacheCreationTokens', 'cache_creation_input_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const sessionId = String(params?.sessionId || '');
    const timestampRaw = obj?.timestamp || params?._meta?.agentTimestampMs;
    const observedAt = normalizeTimestamp(timestampRaw);
    const turnId = update.turnId ?? update.id ?? params?.turnId ?? null;

    yield {
      record_key: turnId
        ? `grok|${sessionId}|${turnId}`
        : `grok|${sessionId}|${observedAt}|${ordinal}`,
      source: 'grok',
      session_id: sessionId || null,
      project_key: null,
      model: sessionModel,
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
