import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileTag, numberedJsonLines, normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

// Third-party evidence: NextAgentX/qoder-trae-workbuddy-switch ab5afe42, token_stats.rs.
const readKeys = ['cache_read_input_tokens', 'cacheReadInputTokens', 'prompt_cache_hit_tokens', 'cached_tokens'];
const writeKeys = ['cache_write_input_tokens', 'cacheWriteInputTokens', 'cache_creation_input_tokens', 'prompt_cache_write_tokens'];

/** Third-party logs can carry stale zero aliases before a positive cache value. */
function cacheOf(objects, keys, notes) {
  let known = null;
  for (const object of objects) for (const key of keys) {
    const value = tokenOf(object, [key], notes);
    if (value > 0) return value;
    if (value === 0) known = 0;
  }
  return known;
}

function record(row, usage, { session, identity, model, cwd, desktop = false, candidates = [usage], rawUsage }, notes) {
  let input = tokenOf(usage, desktop ? ['inputTokens', 'input_tokens', 'prompt_tokens'] : ['input_tokens', 'inputTokens', 'prompt_tokens'], notes);
  const output = tokenOf(usage, desktop ? ['outputTokens', 'output_tokens', 'completion_tokens'] : ['output_tokens', 'outputTokens', 'completion_tokens'], notes);
  const details = [usage?.prompt_tokens_details, ...(Array.isArray(usage?.inputTokensDetails) ? usage.inputTokensDetails : [])];
  const read = cacheOf([usage, ...details], desktop ? ['cacheTokens', ...readKeys] : readKeys, notes);
  const write = cacheOf([...candidates, rawUsage], desktop ? ['cachedWriteTokens', ...writeKeys] : writeKeys, notes);
  const miss = tokenOf(usage, ['prompt_cache_miss_tokens'], notes) ?? tokenOf(rawUsage, ['prompt_cache_miss_tokens'], notes);
  // Third-party Totals::value treats input as inclusive of reads, excluding cache writes.
  if (miss !== null) input = miss;
  else if (input !== null) {
    input -= read ?? 0;
    if (input < 0) { input = null; note(notes, 'bad_fields'); }
  }
  if (isEmptyUsage(input, output, read, write)) { note(notes, 'zero_usage'); return null; }
  const rawTime = row?.timestamp ?? row?.ts ?? (desktop ? row?.startedAt : undefined);
  const observedAt = normalizeTimestamp(typeof rawTime === 'string' && /^\d+$/.test(rawTime.trim()) ? Number(rawTime) : rawTime);
  if (!observedAt) { note(notes, 'bad_times'); return null; }
  return {
    record_key: `codebuddy|${session}|${identity}`, source: 'codebuddy', session_id: session,
    project_key: projectFromCwd(cwd), model: typeof model === 'string' && model.trim() ? model.trim() : null,
    observed_at: observedAt, kind: 'event', input_tokens: input, output_tokens: output,
    cache_read_tokens: read, cache_write_tokens: write, cache_creation_tokens: write
  };
}

export async function* parseCodebuddy(filePath, notes) {
  if (!existsSync(filePath)) return;
  if (filePath.endsWith('.json')) {
    const content = JSON.parse(readFileSync(filePath, 'utf8'));
    if (!Array.isArray(content?.requests)) return;
    const session = basename(dirname(filePath));
    let model = null;
    const metadata = join(dirname(dirname(filePath)), 'index.json');
    if (existsSync(metadata)) {
      try {
        const workspace = JSON.parse(readFileSync(metadata, 'utf8'));
        const conversation = workspace?.conversations?.find(item => item?.id === session);
        model = conversation?.selectedModelId ?? conversation?.modelId ?? conversation?.model ?? null;
      } catch { note(notes, 'bad_lines'); }
    }
    for (const [index, request] of content.requests.entries()) {
      if (!request?.usage) continue;
      const id = typeof request.id === 'string' && request.id.trim() ? request.id : `${fileTag(filePath)}:${index}`;
      const r = record(request, request.usage, { session, identity: id, model, desktop: true }, notes);
      if (r) yield r;
    }
    return;
  }
  const session = basename(filePath, '.jsonl');
  for await (const [row, line] of numberedJsonLines(createReadStream(filePath, { encoding: 'utf8' }), notes)) {
    if (!row || typeof row !== 'object') continue;
    const candidates = [row.message?.usage, row.providerData?.usage, row.usage];
    const usage = candidates.find(value => value && typeof value === 'object' && Object.keys(value).some(key =>
      ['input_tokens', 'inputTokens', 'prompt_tokens', 'prompt_cache_miss_tokens'].includes(key)))
      ?? candidates.find(value => value && typeof value === 'object');
    if (!usage) continue;
    const r = record(row, usage, { session, identity: `${fileTag(filePath)}:${line}`,
      model: row.providerData?.model ?? row.model ?? row.message?.model,
      cwd: row.cwd, candidates, rawUsage: row.providerData?.rawUsage }, notes);
    if (r) yield r;
  }
}
