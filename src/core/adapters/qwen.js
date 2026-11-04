import { createReadStream } from 'node:fs';
import { numberedJsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { isEmptyUsage, minus, note, plus, tokenOf } from './_num.js';

/**
 * 流式解析 Qwen Code 的主账本与侧车账本（token-usage-*.jsonl 与 opus-usage-*.jsonl）。
 * 完整兼容 schemaVersion 1 驼峰格式与早期下划线格式，精准计算未缓存输入、缓存读取与思考 Token。
 * 已确认的认证协议决定 thoughts 包含关系；totalTokens 可能由上游回填，不能覆盖协议口径。
 * 没有 id 的条目用「文件 + 行号」作身份，并用 replaces 指向旧的文件内序号键。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseQwen(filePath, notes) {
  const stream = createReadStream(filePath, { encoding: 'utf8' });
  let ordinal = 0;

  for await (const [obj, lineNo] of numberedJsonLines(stream, notes)) {
    if (!obj || typeof obj !== 'object') continue;

    const rawInput = tokenOf(obj, ['inputTokens', 'input_tokens', 'prompt_tokens'], notes);
    const cachedTokens = tokenOf(obj, ['cachedTokens', 'cached_tokens', 'cache_read_tokens'], notes);

    // 在 schemaVersion 1 驼峰模式下，inputTokens 包含 cachedTokens，需扣除得到纯未缓存输入
    const isCamelCase = obj.inputTokens !== undefined;
    const inputTokens = isCamelCase ? minus(rawInput, cachedTokens) : rawInput;

    const rawOutput = tokenOf(obj, ['outputTokens', 'output_tokens', 'completion_tokens'], notes);
    const thoughtsTokens = tokenOf(obj, ['thoughtsTokens', 'thoughts_tokens'], notes);

    // 上游会回填 input + output + thoughts；完整 completion 已含推理时仍不能再加。
    const total = obj.totalTokens ?? obj.total_tokens;
    let outputTokens;
    if (['openai', 'openai-responses', 'qwen-oauth', 'anthropic'].includes(obj.authType)) {
      // thoughts 是完整输出的已知下界；缺输出或明细大于完整值都需诊断。
      if (thoughtsTokens > 0 && (rawOutput === null || rawOutput < thoughtsTokens)) note(notes, 'bad_fields');
      outputTokens = rawOutput ?? (thoughtsTokens > 0 ? thoughtsTokens : null);
    } else if (['gemini', 'vertex-ai'].includes(obj.authType)) {
      outputTokens = plus(rawOutput, thoughtsTokens);
    } else if (rawInput !== null && rawOutput !== null && Number.isSafeInteger(total) && total > 0 && total === rawInput + rawOutput) {
      // 旧日志无已知认证：仅完整输入输出的等式支持包含判断，其余保留分列回退。
      outputTokens = rawOutput;
    } else {
      outputTokens = plus(rawOutput, thoughtsTokens);
    }

    const cacheCreationTokens = tokenOf(obj, ['cacheWriteTokens', 'cache_write_tokens', 'cache_creation_tokens'], notes);

    if (isEmptyUsage(inputTokens, outputTokens, cachedTokens, cacheCreationTokens)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const sessionId = String(obj.sessionId ?? obj.session_id ?? '');
    const rawModel = obj.model ?? obj.model_name;
    const model = rawModel == null ? null : String(rawModel);
    const observedAt = normalizeTimestamp(obj.timestamp ?? obj.created_at);
    const entryId = obj.id ? String(obj.id) : `${fileTag(filePath)}:${lineNo}`;

    yield {
      record_key: `qwen|${sessionId}|${entryId}`,
      ...(obj.id ? {} : { replaces: [`qwen|${sessionId}|#${ordinal}`] }),
      source: 'qwen',
      session_id: sessionId || null,
      project_key: null,
      model,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      cache_read_tokens: cachedTokens,
      cache_write_tokens: cacheCreationTokens,
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: cacheCreationTokens
    };
  }
}
