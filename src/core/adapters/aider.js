import { createReadStream } from 'node:fs';
import { basename, dirname } from 'node:path';
import { numberedJsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { isEmptyUsage, minus, note, tokenOf } from './_num.js';

/**
 * 流式解析 Aider 交互历史日志（.aider.llm.history）。
 * 兼容多版本 OpenAI / Anthropic / LiteLLM 字段变体。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseAider(filePath, notes) {
  const projectSlug = basename(dirname(filePath));
  const stream = createReadStream(filePath, { encoding: 'utf8' });
  let ordinal = 0;

  for await (const [entry, lineNo] of numberedJsonLines(stream, notes)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;

    // 1. 定位 usage 对象：顶层 > response.usage > choices[0].usage
    const rawUsage =
      entry.usage ??
      entry.response?.usage ??
      entry.choices?.[0]?.usage ??
      null;

    if (!rawUsage) continue;

    // OpenAI 口径的 prompt_tokens 已包含缓存命中部分，anthropic 口径的 input_tokens 不含
    const dialect = rawUsage.prompt_tokens !== undefined && rawUsage.prompt_tokens !== null ? 'openai' : 'anthropic';
    const rawInput = tokenOf(rawUsage, [dialect === 'openai' ? 'prompt_tokens' : 'input_tokens'], notes);
    const outputTokens = tokenOf(rawUsage, ['completion_tokens', 'output_tokens'], notes);
    const cacheReadTokens = rawUsage.cache_read_input_tokens !== undefined && rawUsage.cache_read_input_tokens !== null
      ? tokenOf(rawUsage, ['cache_read_input_tokens'], notes)
      : rawUsage.prompt_tokens_details?.cached_tokens !== undefined && rawUsage.prompt_tokens_details?.cached_tokens !== null
        ? tokenOf(rawUsage.prompt_tokens_details, ['cached_tokens'], notes)
        : tokenOf(rawUsage, ['cached_tokens', 'cache_read'], notes);

    // 包含关系由输入口径决定，不由缓存字段的拼写决定。
    const inputTokens = dialect === 'openai'
      ? minus(rawInput, cacheReadTokens)
      : rawInput;
    const cacheCreationTokens = rawUsage.cache_creation_input_tokens !== undefined && rawUsage.cache_creation_input_tokens !== null
      ? tokenOf(rawUsage, ['cache_creation_input_tokens'], notes)
      : tokenOf(rawUsage.prompt_tokens_details, ['cache_creation_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    const rawModel =
      entry.model ??
      entry.response?.model ??
      entry.model_name;
    const model = rawModel == null ? null : String(rawModel);

    ordinal += 1;
    const rawTs = entry.timestamp ?? entry.created ?? entry.response?.created;
    const observedAt = normalizeTimestamp(rawTs);

    // 会话身份用显式会话标识或项目目录；commit_hash 是一次提交，不是会话
    const sessionId = String(
      entry.session_id ??
      entry.aider_session_id ??
      (projectSlug || 'aider-session')
    );
    const commitHash = entry.commit_hash ? String(entry.commit_hash) : null;

    yield {
      record_key: `aider|${sessionId}|${fileTag(filePath)}:${lineNo}`,
      replaces: [commitHash
        ? `aider|${sessionId}|${commitHash}`
        : `aider|${sessionId}|${observedAt}|${ordinal}`],
      source: 'aider',
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
