import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, toToken } from './_num.js';

/** SDK v1.28.1 的事件文件；同一响应可生成多个工具事件，取最早时间。 */
function responseTimes(directory, notes) {
  let files;
  try {
    files = readdirSync(directory);
  } catch (error) {
    if (error.code === 'ENOENT') return new Map();
    throw error;
  }
  const times = new Map();
  for (const file of files) {
    if (!/^event-\d{5,}-[0-9a-fA-F-]{8,}\.json$/.test(file)) continue;
    let event;
    const raw = readFileSync(join(directory, file), 'utf8');
    try { event = JSON.parse(raw); } catch {
      note(notes, 'bad_lines');
      continue;
    }
    if (!event || typeof event !== 'object' || Array.isArray(event)) {
      note(notes, 'bad_lines');
      continue;
    }
    const id = event.llm_response_id;
    if (typeof id !== 'string' || !id.trim()) continue;
    const timestamp = typeof event.timestamp === 'string' ? normalizeTimestamp(event.timestamp) : null;
    if (timestamp && (!times.has(id) || timestamp < times.get(id))) times.set(id, timestamp);
  }
  return times;
}

/**
 * OpenHands CLI 283c6ac3610f / SDK v1.28.1 的原生会话。
 * 只读逐次用量，按 response_id 关联相邻 events；不回退到累计 stats。
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes]
 */
export async function* parseOpenhands(filePath, notes) {
  if (!existsSync(filePath)) return;
  const state = JSON.parse(readFileSync(filePath, 'utf8'));
  if (!state || typeof state.id !== 'string' || !state.id.trim()) {
    note(notes, 'bad_fields');
    return;
  }
  if (state.agent?.kind !== 'Agent') return;
  const metrics = state.stats?.usage_to_metrics;
  if (!metrics || typeof metrics !== 'object' || Array.isArray(metrics)) {
    note(notes, 'bad_fields');
    return;
  }
  const times = responseTimes(join(dirname(filePath), 'events'), notes);
  for (const [usageId, metric] of Object.entries(metrics)) {
    const missingTimeNote = /^(task:|delegate:|agent-hook:)/.test(usageId) ? 'subagent_copies' : 'bad_times';
    if (!metric || typeof metric !== 'object' || Array.isArray(metric)) {
      note(notes, 'bad_fields');
      continue;
    }
    if (metric.token_usages === undefined) continue;
    if (!Array.isArray(metric.token_usages)) {
      note(notes, 'bad_fields');
      continue;
    }
    const seen = new Map();
    for (const usage of metric.token_usages) {
      if (!usage || typeof usage !== 'object' || Array.isArray(usage)) {
        note(notes, 'bad_fields');
        continue;
      }
      const id = usage.response_id;
      if (typeof id !== 'string' || !id.trim()) {
        note(notes, missingTimeNote);
        continue;
      }
      const occurrence = (seen.get(id) || 0) + 1;
      seen.set(id, occurrence);
      if (occurrence > 1) note(notes, 'duplicate_response_ids');
      const observedAt = times.get(id);
      if (!observedAt) {
        note(notes, missingTimeNote);
        continue;
      }
      const prompt = toToken(usage.prompt_tokens, notes);
      const output = toToken(usage.completion_tokens, notes);
      const cacheRead = toToken(usage.cache_read_tokens, notes);
      const cacheWrite = toToken(usage.cache_write_tokens, notes);
      let input = prompt !== null && cacheRead !== null && cacheWrite !== null
        ? prompt - cacheRead - cacheWrite : null;
      if (input !== null && input < 0) {
        note(notes, 'bad_fields');
        input = null;
      }
      if (isEmptyUsage(input, output, cacheRead, cacheWrite)) {
        note(notes, 'zero_usage');
        continue;
      }
      const model = typeof usage.model === 'string' ? usage.model.trim() : '';
      // 转义分隔符及 #，避免真实 response_id 的后缀与重复序号撞键。
      const identity = [state.id, usageId, id].map(encodeURIComponent).join('|');
      yield {
        record_key: `openhands|${identity}${occurrence > 1 ? `#${occurrence}` : ''}`,
        source: 'openhands', session_id: state.id, project_key: null,
        model: model && !/^(default|unknown)$/i.test(model) ? model : null,
        observed_at: observedAt, kind: 'event', input_tokens: input, output_tokens: output,
        cache_read_tokens: cacheRead, cache_write_tokens: cacheWrite
      };
    }
  }
}
