import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { jsonLines, normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, minus, note, tokenOf } from './_num.js';

/**
 * 从 usageMetadata 或 usage 结构中提取 token 规范数据。
 *
 * @param {any} raw
 * @returns {{ inputTokens: number, outputTokens: number, cacheReadTokens: number, cacheCreationTokens: number }|null}
 */
function extractUsage(raw, notes) {
  if (!raw || typeof raw !== 'object') return null;

  const prompt = tokenOf(raw, ['promptTokenCount', 'prompt_token_count', 'inputTokens', 'input_tokens'], notes);
  const candidates = tokenOf(raw, ['candidatesTokenCount', 'candidates_token_count', 'outputTokens', 'output_tokens'], notes);
  const cached = tokenOf(raw, ['cachedContentTokenCount', 'cached_content_token_count', 'cachedTokens', 'cache_read_tokens'], notes);
  const cacheCreation = tokenOf(raw, ['cacheWriteTokens', 'cache_write_tokens', 'cache_creation_tokens'], notes);

  if (isEmptyUsage(prompt, candidates, cached, cacheCreation)) {
    note(notes, 'zero_usage');
    return null;
  }

  // promptTokenCount 包含缓存时，扣减计算纯输入
  const inputTokens = minus(prompt, cached);

  return {
    inputTokens,
    outputTokens: candidates,
    cacheReadTokens: cached,
    cacheCreationTokens: cacheCreation
  };
}

/**
 * 探测会话中的模型名称。
 *
 * @param {any} obj
 * @returns {string|null}
 */
function detectModel(obj) {
  if (typeof obj?.model === 'string' && obj.model) return obj.model;
  if (typeof obj?.modelId === 'string' && obj.modelId) return obj.modelId;

  if (Array.isArray(obj?.messages)) {
    for (const msg of obj.messages) {
      if (msg.role === 'model' && typeof msg.model === 'string' && msg.model) {
        return msg.model;
      }
    }
  }

  return null;
}

/**
 * 流式解析 Google 官方 Gemini CLI 会话日志（支持单个 JSON 会话或 JSONL 流文件）。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseGemini(filePath, notes) {
  if (!existsSync(filePath)) return;

  const ext = extname(filePath).toLowerCase();
  const fileSessionId = basename(filePath, ext).replace(/^session-/, '');

  if (ext === '.jsonl') {
    // 处理 JSONL 格式（一行一条记录）
    const stream = createReadStream(filePath, { encoding: 'utf8' });
    let ordinal = 0;
    for await (const obj of jsonLines(stream, notes)) {
      if (!obj || typeof obj !== 'object') continue;

      const usage = extractUsage(obj.usageMetadata ?? obj.usage, notes);
      if (!usage) continue;

      ordinal += 1;
      const sessionId = String(obj.id ?? obj.sessionId ?? fileSessionId);
      const model = detectModel(obj);
      const observedAt = normalizeTimestamp(obj.startTime ?? obj.createTime ?? obj.timestamp);

      yield {
        // JSONL 行没有可确认的消息 id，用时间 + 文件内序号作身份
        record_key: `gemini|${sessionId}|${observedAt}|${ordinal}`,
        source: 'gemini',
        session_id: sessionId || null,
        project_key: null,
        model,
        observed_at: observedAt,
        kind: 'event',
        input_tokens: usage.inputTokens,
        output_tokens: usage.outputTokens,
        cache_read_tokens: usage.cacheReadTokens,
        cache_write_tokens: usage.cacheCreationTokens,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: usage.cacheCreationTokens
      };
    }
  } else {
    // 处理单个 JSON 会话文件
    const raw = readFileSync(filePath, 'utf8');
    const data = JSON.parse(raw);

    if (!data || typeof data !== 'object') return;

    const sessionId = String(data.id ?? data.sessionId ?? fileSessionId);
    const sessionModel = detectModel(data);

    // 策略 A：顶层整体会话汇总
    const topUsage = extractUsage(data.usageMetadata ?? data.usage, notes);
    if (topUsage) {
      const observedAt = normalizeTimestamp(data.startTime ?? data.createTime ?? data.timestamp);
      yield {
        // 单文件整体汇总：一个会话只有一个有效版本
        record_key: `gemini|${sessionId}`,
        source: 'gemini',
        session_id: sessionId || null,
        project_key: null,
        model: sessionModel,
        observed_at: observedAt,
        kind: 'cumulative',
        input_tokens: topUsage.inputTokens,
        output_tokens: topUsage.outputTokens,
        cache_read_tokens: topUsage.cacheReadTokens,
        cache_write_tokens: topUsage.cacheCreationTokens,
        // 兼容别名：Phase 1 收尾时随旧 store 一起删除
        timestamp: observedAt,
        cache_creation_tokens: topUsage.cacheCreationTokens
      };
      return;
    }

    // 策略 B：逐消息轮次计量
    if (Array.isArray(data.messages)) {
      let ordinal = 0;
      for (const msg of data.messages) {
        if (!msg || typeof msg !== 'object') continue;
        if (msg.role !== 'model' && msg.role !== 'assistant') continue;

        const msgUsage = extractUsage(msg.usageMetadata ?? msg.usage, notes);
        if (!msgUsage) continue;

        ordinal += 1;
        const rawModel = msg.model || sessionModel;
        const model = rawModel == null ? null : String(rawModel);
        const observedAt = normalizeTimestamp(msg.createTime ?? msg.timestamp ?? data.startTime);

        yield {
          record_key: `gemini|${sessionId}|${observedAt}|${ordinal}`,
          source: 'gemini',
          session_id: sessionId || null,
          project_key: null,
          model,
          observed_at: observedAt,
          kind: 'event',
          input_tokens: msgUsage.inputTokens,
          output_tokens: msgUsage.outputTokens,
          cache_read_tokens: msgUsage.cacheReadTokens,
          cache_write_tokens: msgUsage.cacheCreationTokens,
          // 兼容别名：Phase 1 收尾时随旧 store 一起删除
          timestamp: observedAt,
          cache_creation_tokens: msgUsage.cacheCreationTokens
        };
      }
    }
  }
}
