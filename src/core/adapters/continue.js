import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 从交互轮次或消息体中提取模型名称。
 */
function extractModel(round, sessionModel) {
  if (typeof round.modelTitle === 'string' && round.modelTitle) return round.modelTitle;
  if (typeof round.model === 'string' && round.model) return round.model;
  if (round.selectedModel && typeof round.selectedModel.title === 'string') return round.selectedModel.title;
  if (round.message && typeof round.message.model === 'string') return round.message.model;
  return sessionModel || null;
}

/**
 * 从轮次对象中提取 Token 用量。
 */
function extractRoundUsage(round, notes) {
  // 1. 顶层 promptTokens / completionTokens
  let input = tokenOf(round, ['promptTokens', 'inputTokens', 'input_tokens'], notes);
  let output = tokenOf(round, ['completionTokens', 'outputTokens', 'output_tokens'], notes);
  let cacheRead = tokenOf(round, ['cachedTokens', 'cache_read_input_tokens'], notes);

  // 2. 嵌套 usage 对象
  const u = round.usage || round.message?.usage;
  if (u && typeof u === 'object') {
    if (input === null) input = tokenOf(u, ['prompt_tokens', 'promptTokens', 'input_tokens'], notes);
    if (output === null) output = tokenOf(u, ['completion_tokens', 'completionTokens', 'output_tokens'], notes);
    if (cacheRead === null) cacheRead = tokenOf(u, ['cache_read_input_tokens', 'cached_tokens'], notes);
  }

  // 3. 嵌套 tokenCount 对象
  const tc = round.tokenCount || round.message?.tokenCount;
  if (tc && typeof tc === 'object') {
    if (input === null) input = tokenOf(tc, ['input', 'prompt'], notes);
    if (output === null) output = tokenOf(tc, ['output', 'completion'], notes);
  }

  if (isEmptyUsage(input, output, cacheRead, null)) {
    note(notes, 'zero_usage');
    return null;
  }

  return { input, output, cacheRead };
}

/**
 * 流式解析 Continue.dev 的会话文件（*.json）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseContinue(filePath, notes) {
  let content;
  try {
    content = await readFile(filePath, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return;
    throw err;
  }
  const data = JSON.parse(content);

  if (!data || typeof data !== 'object') return;

  const fileSessionId = basename(filePath, '.json');
  const sessionId = String(data.sessionId || data.id || fileSessionId);
  const sessionModel = typeof data.modelTitle === 'string' ? data.modelTitle : null;
  const defaultTimestamp = normalizeTimestamp(data.dateCreated || data.timestamp);

  const history = Array.isArray(data.history)
    ? data.history
    : Array.isArray(data.messages)
      ? data.messages
      : [];

  let emitted = false;
  let ordinal = 0;

  for (const round of history) {
    if (!round || typeof round !== 'object') continue;

    const role = round.role || round.message?.role;
    // 只处理 assistant 角色回复的用量
    if (role && role !== 'assistant' && role !== 'model') continue;

    const usage = extractRoundUsage(round, notes);
    if (!usage) continue;

    ordinal += 1;
    const model = extractModel(round, sessionModel);
    const roundTs = round.timestamp ?? round.dateCreated ?? round.time;
    const observedAt = roundTs ? normalizeTimestamp(roundTs) : defaultTimestamp;
    const roundId = round.messageId ?? round.id ?? null;

    yield {
      record_key: roundId
        ? `continue|${sessionId}|${roundId}`
        : `continue|${sessionId}|${observedAt}|${ordinal}`,
      source: 'continue',
      session_id: sessionId || null,
      project_key: null,
      model,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: usage.input,
      output_tokens: usage.output,
      cache_read_tokens: usage.cacheRead,
      cache_write_tokens: null,
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: null
    };
    emitted = true;
  }

  // 若没有从 history 提取出明细，但会话顶层包含总 tokenCount 且之前未 yield
  if (!emitted && data.tokenCount && typeof data.tokenCount === 'object') {
    const input = tokenOf(data.tokenCount, ['input', 'prompt'], notes);
    const output = tokenOf(data.tokenCount, ['output', 'completion'], notes);
    if (isEmptyUsage(input, output, null, null)) {
      note(notes, 'zero_usage');
    } else {
      yield {
        // 顶层汇总是整场会话的一个值
        record_key: `continue|${sessionId}`,
        source: 'continue',
        session_id: sessionId || null,
        project_key: null,
        model: sessionModel || null,
        observed_at: defaultTimestamp,
        kind: 'cumulative',
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: null,
        cache_write_tokens: null,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: defaultTimestamp,
        cache_creation_tokens: null
      };
    }
  }
}
