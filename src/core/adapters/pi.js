import { createReadStream } from 'node:fs';
import { basename } from 'node:path';
import { numberedJsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { firstProject } from './_project.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 流式解析 Pi Coding Agent 会话日志（*.jsonl）。
 * 没有 id 的条目用「文件 + 行号」作身份，并用 replaces 指向旧的文件内序号键。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parsePi(filePath, notes) {
  let currentSessionId = basename(filePath, '.jsonl').replace(/^.*_/, '');
  let currentModel = null;
  let currentProvider = null;
  let currentProjectKey = null;
  let ordinal = 0;

  const stream = createReadStream(filePath, { encoding: 'utf8' });

  for await (const [obj, lineNo] of numberedJsonLines(stream)) {
    if (!obj || typeof obj !== 'object') continue;

    // 1. 继承 session 事件中的会话 ID；工作目录取自 session 行，不从文件路径猜
    if (obj.type === 'session') {
      if (obj.id) {
        currentSessionId = String(obj.id);
      }
      currentProjectKey = firstProject(obj.cwd);
    }

    // 2. 跟踪 model_change 事件
    if (obj.type === 'model_change' && (obj.modelId || obj.model)) {
      currentModel = String(obj.modelId || obj.model);
      currentProvider = typeof obj.provider === 'string' && obj.provider.trim() ? obj.provider : null;
    }

    // 3. 提取 message 事件中 assistant 的 usage
    if (obj.type === 'message' && obj.message) {
      const msg = obj.message;
      if (msg.role !== 'assistant') continue;

      const usage = msg.usage;
      if (!usage) continue;

      const inputTokens = tokenOf(usage, ['input', 'prompt_tokens'], notes);
      const outputTokens = tokenOf(usage, ['output', 'completion_tokens'], notes);
      const cacheReadTokens = tokenOf(usage, ['cacheRead', 'cache_read_input_tokens'], notes);
      const cacheCreationTokens = tokenOf(usage, ['cacheWrite', 'cache_creation_input_tokens'], notes);

      if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
        note(notes, 'zero_usage');
        continue;
      }

      ordinal += 1;
      const rawModel = msg.model || currentModel;
      const model = rawModel == null ? null : String(rawModel);
      // 仅继承与模型同一条 model_change 写出的提供方，不给消息自报的其他模型补提供方。
      const rawProvider = msg.provider ?? (msg.model ? null : currentProvider);
      const observedAt = normalizeTimestamp(obj.timestamp || msg.timestamp);
      const messageId = obj.id ? String(obj.id) : `${fileTag(filePath)}:${lineNo}`;

      yield {
        record_key: `pi|${currentSessionId}|${messageId}`,
        ...(obj.id ? {} : { replaces: [`pi|${currentSessionId}|#${ordinal}`] }),
        source: 'pi',
        session_id: currentSessionId || null,
        project_key: currentProjectKey,
        model,
        provider: typeof rawProvider === 'string' && rawProvider.trim() ? rawProvider : null,
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
}
