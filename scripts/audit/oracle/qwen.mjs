import { entry, jsonLines, readFiles } from './common.mjs';

// Qwen accepts nonnegative integer numbers and trimmed digit-only strings.
// Keep this conversion local: other sources use the stricter common count.
function token(value) {
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0) return value;
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) return Number(value.trim());
  return null;
}

export async function oracle(options = {}) {
  return readFiles('qwen', options, async (file, issues) => {
    const entries = [];
    for await (const { value: row, line } of jsonLines(file, issues)) {
      const session = row.sessionId ?? row.session_id ?? null;
      const rawInput = token(row.inputTokens ?? row.input_tokens ?? row.prompt_tokens);
      const cached = token(row.cachedTokens ?? row.cached_tokens ?? row.cache_read_tokens);
      const input = row.inputTokens !== undefined && rawInput !== null ? Math.max(0, rawInput - (cached ?? 0)) : rawInput;
      const output = token(row.outputTokens ?? row.output_tokens ?? row.completion_tokens);
      const thoughts = token(row.thoughtsTokens ?? row.thoughts_tokens);
      const total = row.totalTokens ?? row.total_tokens;
      let normalizedOutput;
      if (['openai', 'openai-responses', 'qwen-oauth', 'anthropic'].includes(row.authType)) {
        if (thoughts > 0 && (output === null || output < thoughts)) issues.push({ type: 'bad_fields', file, line });
        normalizedOutput = output ?? (thoughts > 0 ? thoughts : null);
      } else if (['gemini', 'vertex-ai'].includes(row.authType)) {
        normalizedOutput = output === null && thoughts === null ? null : (output ?? 0) + (thoughts ?? 0);
      } else if (rawInput !== null && output !== null && Number.isSafeInteger(total) && total > 0 && total === rawInput + output) {
        normalizedOutput = output;
      } else {
        normalizedOutput = output === null && thoughts === null ? null : (output ?? 0) + (thoughts ?? 0);
      }
      const written = token(row.cacheWriteTokens ?? row.cache_write_tokens ?? row.cache_creation_tokens);
      if ([input, normalizedOutput, cached, written].every(value => value === null || value === 0)) continue;
      entries.push(entry('qwen', session, JSON.stringify([session, row.id ?? `file:${file}:${line}`]), file, line, row.timestamp, {
        input,
        output: normalizedOutput,
        cache_read: cached, cache_write: written
      }, { id: row.id ?? null, input: rawInput, output, cached, thoughts, total: row.totalTokens ?? null }));
    }
    return { entries };
  });
}
