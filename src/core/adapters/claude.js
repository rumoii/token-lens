import { createReadStream } from 'node:fs';
import { numberedJsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { firstProject } from './_project.js';
import { isEmptyUsage, note, toToken, tokenOf } from './_num.js';

const USAGE_FIELDS = [
  'input_tokens',
  'output_tokens',
  'cache_read_input_tokens',
  'cache_creation_input_tokens'
];

/**
 * 从 Claude 日志行中提取消息 ID。
 *
 * @param {any} obj
 * @returns {string|null}
 */
function extractMessageId(obj) {
  if (obj?.message?.id && typeof obj.message.id === 'string') {
    return obj.message.id;
  }
  if (obj?.id && typeof obj.id === 'string' && obj.id.startsWith('msg_')) {
    return obj.id;
  }
  return null;
}

/**
 * 提取用量原始字段。
 *
 * 缓存写分两档上报（`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`），
 * 单价不同。只有两档齐全且之和等于合计时才采信，否则只保留合计。
 * 没写的字段是未知（null），不是 0。
 *
 * @param {any} obj
 * @param {import('./_num.js').ParseNotes} [notes]
 * @returns {Object|null} 没有 usage 或四类都为 0、未知时为 null
 */
function extractUsage(obj, notes) {
  const u = obj?.message?.usage || obj?.usage;
  if (!u || typeof u !== 'object') return null;

  const result = {
    input_tokens: tokenOf(u, ['input_tokens'], notes),
    output_tokens: tokenOf(u, ['output_tokens'], notes),
    cache_read_input_tokens: tokenOf(u, ['cache_read_input_tokens', 'cached_input_tokens'], notes),
    cache_creation_input_tokens: tokenOf(u, ['cache_creation_input_tokens'], notes)
  };

  const split = u.cache_creation;
  if (split && typeof split === 'object') {
    const fiveMinute = toToken(split.ephemeral_5m_input_tokens, notes);
    const oneHour = toToken(split.ephemeral_1h_input_tokens, notes);
    if (fiveMinute !== null && oneHour !== null) {
      result.cache_write_5m_tokens = fiveMinute;
      result.cache_write_1h_tokens = oneHour;
    }
  }

  if (isEmptyUsage(...USAGE_FIELDS.map((f) => result[f]))) {
    note(notes, 'zero_usage');
    return null;
  }
  return result;
}

/**
 * 取较大值；一边未知时取另一边，两边都未知仍为未知。
 *
 * @param {number|null|undefined} a
 * @param {number|null|undefined} b
 * @returns {number|null}
 */
function maxKnown(a, b) {
  if (a === null || a === undefined) return b ?? null;
  if (b === null || b === undefined) return a;
  return Math.max(a, b);
}

/**
 * 对同一消息的多个流式快照进行 Max 合并，保留最终完成状态。
 *
 * @param {Object} target
 * @param {Object} source
 */
function mergeMaxUsage(target, source) {
  for (const f of USAGE_FIELDS) {
    target[f] = maxKnown(target[f], source[f]);
  }
  for (const f of ['cache_write_5m_tokens', 'cache_write_1h_tokens']) {
    const next = source[f];
    if (next === undefined) continue;
    target[f] = target[f] === undefined ? next : Math.max(target[f], next);
  }
}

/**
 * 合并后的分档是否仍然自洽。不自洽就只报合计，不报分档。
 *
 * @param {Object} usage
 * @returns {{ cache_write_5m_tokens?: number, cache_write_1h_tokens?: number }}
 */
function splitOf(usage) {
  const fiveMinute = usage.cache_write_5m_tokens;
  const oneHour = usage.cache_write_1h_tokens;
  if (fiveMinute === undefined || oneHour === undefined) return {};
  if (fiveMinute + oneHour !== usage.cache_creation_input_tokens) return {};
  return { cache_write_5m_tokens: fiveMinute, cache_write_1h_tokens: oneHour };
}

/**
 * 流式解析 Claude Code 的项目会话日志文件。
 * 通过在单文件生命周期内按 message.id 分桶并执行 max-merge，彻底消灭流式快照重复累计导致的虚增。
 *
 * 身份是 `claude|<message.id>`，不含会话：分支或续接会把历史消息连同 id 复制进新会话的文件，
 * 同一条消息只能计一次（跨文件取舍由 ingest 完成）。没有 message.id 的行用行自带的 uuid，
 * 复制时 uuid 同样保留；连 uuid 都没有才用「文件 + 行号」。
 * 每条记录用 `replaces` 指向第 1 版的旧键（`claude|<session>|<id>`、`claude|<session>|#n`）。
 *
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes] 由 ingest 传入的解析计数
 * @yields {Object} 统一的用量记录项
 */
export async function* parseClaude(filePath, notes) {
  const stream = createReadStream(filePath, { encoding: 'utf8' });

  // Map<messageId, { sessionId, model, timestamp, usage }>
  const messageBucket = new Map();
  const orphanRecords = [];
  let projectKey = null;

  for await (const [obj, lineNo] of numberedJsonLines(stream, notes)) {
    if (!obj || typeof obj !== 'object') continue;

    // 会话级归属：同一条日志的 cwd 只会有一个，取到就不再覆盖
    if (!projectKey) projectKey = firstProject(obj.cwd);

    const usage = extractUsage(obj, notes);
    if (!usage) continue;

    const msgId = extractMessageId(obj);
    const sessionId = String(obj.sessionId || '');
    const rawModel = obj?.message?.model || obj?.model;
    const model = rawModel ? String(rawModel) : null;
    const timestamp = normalizeTimestamp(obj.timestamp);

    if (msgId) {
      if (messageBucket.has(msgId)) {
        const existing = messageBucket.get(msgId);
        mergeMaxUsage(existing.usage, usage);
        if (model && !existing.model) {
          existing.model = model;
        }
        if (timestamp && !existing.timestamp) {
          existing.timestamp = timestamp;
        }
      } else {
        messageBucket.set(msgId, {
          sessionId,
          model,
          timestamp,
          usage: { ...usage }
        });
      }
    } else {
      orphanRecords.push({
        uuid: typeof obj.uuid === 'string' && obj.uuid ? obj.uuid : null,
        lineNo,
        sessionId,
        model,
        timestamp,
        usage
      });
    }
  }

  // 1. 先 yield 所有去重并合并至最大完成态的消息记录
  for (const [msgId, entry] of messageBucket) {
    const observedAt = entry.timestamp;
    yield {
      record_key: `claude|${msgId}`,
      replaces: [`claude|${entry.sessionId || ''}|${msgId}`],
      source: 'claude',
      session_id: entry.sessionId || null,
      project_key: projectKey,
      model: entry.model || null,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: entry.usage.input_tokens,
      output_tokens: entry.usage.output_tokens,
      cache_read_tokens: entry.usage.cache_read_input_tokens,
      cache_write_tokens: entry.usage.cache_creation_input_tokens,
      ...splitOf(entry.usage),
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: entry.usage.cache_creation_input_tokens
    };
  }

  // 2. 补充孤立无 ID 记录：用行 uuid，没有就用文件与行号；第 1 版用的是文件内序号
  let orphanIndex = 0;
  for (const entry of orphanRecords) {
    orphanIndex += 1;
    const observedAt = entry.timestamp;
    yield {
      record_key: `claude|${entry.uuid || `${fileTag(filePath)}:${entry.lineNo}`}`,
      replaces: [`claude|${entry.sessionId || ''}|#${orphanIndex}`],
      source: 'claude',
      session_id: entry.sessionId || null,
      project_key: projectKey,
      model: entry.model || null,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: entry.usage.input_tokens,
      output_tokens: entry.usage.output_tokens,
      cache_read_tokens: entry.usage.cache_read_input_tokens,
      cache_write_tokens: entry.usage.cache_creation_input_tokens,
      ...splitOf(entry.usage),
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: entry.usage.cache_creation_input_tokens
    };
  }
}

