import { existsSync, readFileSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 安全读取 JSON 文件。
 *
 * @param {string} filePath
 * @returns {any|null}
 */
function readJsonSafe(filePath, notes) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    note(notes, 'bad_lines');
    return null;
  }
}

/**
 * 从同级 ui_messages.json 中构建时间有序的 model 时间线，用于缺失 model 时的回退。
 *
 * @param {Array<any>} uiMessages
 * @returns {Array<{ ts: number, model: string }>}
 */
function buildModelTimeline(uiMessages, notes) {
  if (!Array.isArray(uiMessages)) return [];

  const timeline = [];

  for (const msg of uiMessages) {
    if (msg.say === 'api_req_started' && typeof msg.text === 'string') {
      try {
        const parsed = JSON.parse(msg.text);
        const model = parsed.model || parsed.request?.model;
        if (model && msg.ts) {
          timeline.push({ ts: Number(msg.ts), model: String(model) });
        }
      } catch {
        note(notes, 'bad_lines');
      }
    } else if (msg.apiConfiguration?.model) {
      timeline.unshift({ ts: 0, model: String(msg.apiConfiguration.model) });
    }
  }

  timeline.sort((a, b) => a.ts - b.ts);
  return timeline;
}

/**
 * 根据消息时间戳二分查找到时间最近的 model。
 *
 * @param {Array<{ ts: number, model: string }>} timeline
 * @param {number} ts
 * @returns {string|null}
 */
function resolveModelAtTime(timeline, ts) {
  if (!timeline.length) return null;

  let lo = 0;
  let hi = timeline.length - 1;
  let best = -1;

  while (lo <= hi) {
    const mid = (lo + hi) >>> 1;
    if (timeline[mid].ts <= ts) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }

  return best >= 0 ? timeline[best].model : timeline[0].model;
}

/**
 * 流式解析 Cline 或 Roo Code 的任务对话文件（api_conversation_history.json）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseCline(filePath, notes) {
  if (!existsSync(filePath)) return;

  const messages = JSON.parse(readFileSync(filePath, 'utf8'));
  if (!Array.isArray(messages) || messages.length === 0) return;

  const taskDir = dirname(filePath);
  const taskId = basename(taskDir);

  // 延迟载入同级 ui_messages.json，获取 model 映射
  const uiMessagesPath = join(taskDir, 'ui_messages.json');
  const uiMessages = existsSync(uiMessagesPath) ? readJsonSafe(uiMessagesPath, notes) : null;
  const modelTimeline = buildModelTimeline(uiMessages, notes);

  let ordinal = 0;

  for (const msg of messages) {
    if (msg.role !== 'assistant') continue;

    const usage = msg.usage;
    if (!usage || typeof usage !== 'object') continue;

    const inputTokens = tokenOf(usage, ['input_tokens'], notes);
    const outputTokens = tokenOf(usage, ['output_tokens'], notes);
    const cacheReadTokens = tokenOf(usage, ['cache_read_input_tokens'], notes);
    const cacheCreationTokens = tokenOf(usage, ['cache_creation_input_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const ts = Number(msg.ts || 0);
    const rawModel = msg.model || resolveModelAtTime(modelTimeline, ts);
    const model = rawModel == null ? null : String(rawModel);
    const observedAt = normalizeTimestamp(ts || undefined);
    const messageId = msg.id ?? msg.messageId ?? null;

    yield {
      record_key: messageId
        ? `cline|${taskId}|${messageId}`
        : `cline|${taskId}|${observedAt}|${ordinal}`,
      source: 'cline',
      session_id: taskId || null,
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
