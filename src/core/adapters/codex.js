import { createReadStream, readFileSync } from 'node:fs';
import { Readable } from 'node:stream';
import { decompressZstdFrames } from './_zstd.js';
import { numberedJsonLines, normalizeTimestamp, fileTag } from './_lines.js';
import { firstProject } from './_project.js';
import { isEmptyUsage, minus, note, tokenOf } from './_num.js';

/**
 * 从一条 Codex `token_usage_record` 中取出 per-response 用量。
 *
 * 该 payload 同时带三种表示：
 *   - usage（本次响应）
 *   - turn_token_usage（本轮累计）
 *   - thread_token_usage（整段会话累计）
 * 只取 usage，其余一律忽略，否则同一笔用量会被计多次。
 *
 * @param {any} usage
 * @param {import('./_num.js').ParseNotes} [notes]
 * @returns {{ input: number|null, output: number|null, cacheRead: number|null, cacheWrite: null }}
 */
function normalizeUsage(usage, notes) {
  const cached = tokenOf(usage, ['cached_input_tokens', 'cache_read_input_tokens', 'cache_read_tokens'], notes);

  // 该客户端的 cached 是 input 的子集（实测 190798 / 181376 / 382，total = input + output）。
  // 落库要求四类互不重叠，因此把缓存段从 input 里扣掉。
  return {
    input: minus(tokenOf(usage, ['input_tokens', 'prompt_tokens'], notes), cached),
    output: tokenOf(usage, ['output_tokens', 'completion_tokens'], notes),
    cacheRead: cached,
    cacheWrite: null
  };
}

/**
 * 流式解析 Codex 会话 Rollout 文件（支持 .jsonl 及 .jsonl.zst）。
 *
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes] 由 ingest 传入的解析计数
 * @yields {Object} 统一的用量记录项
 */
export async function* parseCodex(filePath, notes) {
  let stream;
  if (filePath.endsWith('.zst')) {
    const compressed = readFileSync(filePath);
    const decompressed = decompressZstdFrames(compressed);
    stream = Readable.from(decompressed);
  } else {
    stream = createReadStream(filePath, { encoding: 'utf8' });
  }

  let currentSessionId = null;
  let projectKey = null;
  let currentModel = null;
  let currentProvider = null;
  let ordinal = 0;
  // 客户端压缩替换 rollout 时，物理行号与逻辑文件身份保持不变。
  const positionTag = fileTag(filePath.endsWith('.zst') ? filePath.slice(0, -4) : filePath);

  for await (const [obj, lineNo] of numberedJsonLines(stream, notes)) {
    const payload = obj?.payload || obj;

    if (obj?.type === 'session_meta') {
      currentProvider = typeof payload.model_provider === 'string' && payload.model_provider.trim()
        ? payload.model_provider : null;
    }

    if (payload.session_id) {
      currentSessionId = String(payload.session_id);
    }
    if (!projectKey) {
      projectKey = firstProject(payload.cwd, payload.working_directory);
    }
    if (typeof payload.model === 'string' && payload.model) {
      currentModel = payload.model;
    }

    // 只有 token_usage_record 的 payload 带 per-response 用量
    if (obj?.type !== 'token_usage_record') continue;

    const usage = payload.usage;
    if (!usage || typeof usage !== 'object') continue;

    const tokens = normalizeUsage(usage, notes);
    if (isEmptyUsage(tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite)) {
      note(notes, 'zero_usage');
      continue;
    }

    ordinal += 1;
    const sessionId = payload.session_id ? String(payload.session_id) : currentSessionId;
    const model = typeof usage.model === 'string' ? usage.model : currentModel;
    const observedAt = normalizeTimestamp(obj.timestamp || payload.timestamp);
    const responseId = payload.response_id || null;

    const recordKey = responseId
      ? `codex|${sessionId || ''}|${responseId}`
      : `codex|${sessionId || ''}|${positionTag}:${lineNo}`;

    yield {
      record_key: recordKey,
      ...(!responseId ? { replaces: [payload.turn_id
        ? `codex|${sessionId || ''}|${payload.turn_id}`
        : `codex|${sessionId || ''}|${observedAt}|${ordinal}`] } : {}),
      source: 'codex',
      session_id: sessionId ?? null,
      project_key: projectKey,
      model: model ?? null,
      provider: currentProvider,
      observed_at: observedAt,
      kind: 'event',
      input_tokens: tokens.input,
      output_tokens: tokens.output,
      cache_read_tokens: tokens.cacheRead,
      cache_write_tokens: tokens.cacheWrite,
      // 兼容别名：Phase 1 收尾时随旧 store 一起删除
      timestamp: observedAt,
      cache_creation_tokens: null
    };
  }
}


