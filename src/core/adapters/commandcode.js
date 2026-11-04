import { createReadStream, existsSync } from 'node:fs';
import { numberedJsonLines, normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

/** command-code 1.88.2: v3 appendMessage / toSessionUsage / estimateCatalogCostUsd. */
export async function* parseCommandcode(filePath, notes) {
  if (!existsSync(filePath)) return;
  let header;
  for await (const [row] of numberedJsonLines(createReadStream(filePath, { encoding: 'utf8' }), notes)) {
    if (!header) {
      if (row?.type !== 'session' || row.version !== 3 || typeof row.id !== 'string' || !row.id.trim()) {
        note(notes, 'bad_lines');
        return;
      }
      header = row;
      continue;
    }
    if (row?.type !== 'message' || row.message?.role !== 'assistant' || !row.usage) continue;
    if (typeof row.id !== 'string' || !row.id.trim()) { note(notes, 'bad_lines'); continue; }
    let input = tokenOf(row.usage, ['inputTokens'], notes);
    const output = tokenOf(row.usage, ['outputTokens'], notes);
    const read = tokenOf(row.usage, ['cacheReadTokens'], notes);
    const write = tokenOf(row.usage, ['cacheWriteTokens'], notes);
    // The published cost calculator deducts both caches from inputTokens.
    if (input !== null) {
      input -= (read ?? 0) + (write ?? 0);
      if (input < 0) { input = null; note(notes, 'bad_fields'); }
    }
    if (isEmptyUsage(input, output, read, write)) { note(notes, 'zero_usage'); continue; }
    const observedAt = normalizeTimestamp(row.timestamp);
    if (!observedAt) { note(notes, 'bad_times'); continue; }
    let oneHour = tokenOf(row.usage, ['cacheWriteTokens1h'], notes);
    if (oneHour !== null && (write === null || oneHour > write)) {
      oneHour = null;
      note(notes, 'bad_fields');
    }
    yield {
      record_key: `commandcode|${header.id}|${row.id}`,
      source: 'commandcode', session_id: header.id,
      project_key: projectFromCwd(header.cwd),
      model: typeof row.model === 'string' && row.model.trim() ? row.model.trim() : null,
      observed_at: observedAt, kind: 'event',
      input_tokens: input, output_tokens: output, cache_read_tokens: read, cache_write_tokens: write,
      cache_write_1h_tokens: oneHour,
      cache_write_5m_tokens: oneHour === null ? null : write - oneHour
    };
  }
}
