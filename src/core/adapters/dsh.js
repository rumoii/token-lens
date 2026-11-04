import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { normalizeTimestamp } from './_lines.js';
import { firstProject } from './_project.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/**
 * 流式解析 DSH (DeepSeek Harness) 的会话文件。
 *
 * @param {string} filePath
 * @yields {Object} 统一的用量记录项
 */
export async function* parseDsh(filePath, notes) {
  const content = await readFile(filePath, 'utf8');
  const data = JSON.parse(content);
  const rows = data?.record?.rows;
  if (!rows) return;

  const totals = rows?.tokenUsage?.val?.totals;
  if (!totals) return;

  // 合法的 0 不回落到别的字段；缺字段是未知，记 null 而不是补 0
  const input = tokenOf(totals, ['uncachedInputTokens', 'inputTokens'], notes);
  const output = tokenOf(totals, ['outputTokens'], notes);
  const cache_read = tokenOf(totals, ['cacheReadTokens'], notes);
  const cache_write = tokenOf(totals, ['cacheWriteTokens'], notes);

  if (isEmptyUsage(input, output, cache_read, cache_write)) {
    note(notes, 'zero_usage');
    return;
  }

  const sessionId = basename(filePath, '.json').replace(/^session-/, '');
  const modelRaw = rows?.modelSelection?.val?.lastUsed?.model;
  // 模型缺失时不猜默认值，记 null，不计价
  const model = typeof modelRaw === 'string' && modelRaw.trim() !== '' ? modelRaw : null;
  const createdAt = data?.record?.identity?.createdAt;
  const observedAt = normalizeTimestamp(createdAt);
  // 快照覆盖到的最后一条消息。缺失或早于开始时间都按未知处理，查询层会把它留在 unallocated
  const lastMessageTime = rows?.timeContext?.val?.lastMessageTime;
  const endedAt = lastMessageTime ? normalizeTimestamp(lastMessageTime) : null;
  const ended_at = endedAt && observedAt && endedAt >= observedAt ? endedAt : null;

  yield {
    // 全量覆写文件：一个会话只有一个有效版本，身份里不能带 token 数
    record_key: `dsh|${sessionId}`,
    source: 'dsh',
    session_id: sessionId,
    project_key: firstProject(data?.record?.identity?.cwd, rows?.workingDirectory?.val),
    model,
    observed_at: observedAt,
    ended_at,
    kind: 'cumulative',
    input_tokens: input,
    output_tokens: output,
    cache_read_tokens: cache_read,
    cache_write_tokens: cache_write,
    // 兼容别名：Phase 1 收尾时随旧 store 一起删除
    timestamp: observedAt,
    cache_creation_tokens: cache_write
  };
}
