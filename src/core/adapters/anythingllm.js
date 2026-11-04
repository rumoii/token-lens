import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';

/** AnythingLLM 9caf2b4c: workspace_chats.response.metrics; include=false still incurred usage. */
export async function* parseAnythingllm(filePath, notes) {
  if (!existsSync(filePath)) return;
  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_chats'").get()) return;
    // SELECT * also accepts older schemas without thread_id / api_session_id.
    for (const row of db.prepare('SELECT * FROM workspace_chats ORDER BY id').iterate()) {
      let response;
      try { response = JSON.parse(row.response); } catch { note(notes, 'bad_lines'); continue; }
      const metrics = response?.metrics;
      if (!metrics || typeof metrics !== 'object' || Array.isArray(metrics)) continue;
      const input = tokenOf(metrics, ['prompt_tokens'], notes);
      const output = tokenOf(metrics, ['completion_tokens'], notes);
      if (isEmptyUsage(input, output)) { note(notes, 'zero_usage'); continue; }
      // Prisma SQLite DateTime is milliseconds; CURRENT_TIMESTAMP defaults are UTC SQL text.
      const raw = typeof row.createdAt === 'string' && /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?$/.test(row.createdAt)
        ? row.createdAt.replace(' ', 'T') + 'Z' : row.createdAt;
      const observedAt = normalizeTimestamp(raw);
      if (!observedAt) { note(notes, 'bad_times'); continue; }
      const session = `${row.workspaceId}|${row.api_session_id != null
        ? `api:${row.api_session_id}` : `thread:${row.thread_id ?? 'main'}`}`;
      yield {
        record_key: `anythingllm|${row.workspaceId}|${row.id}`,
        source: 'anythingllm', session_id: session, project_key: null,
        model: typeof metrics.model === 'string' && metrics.model.trim() ? metrics.model.trim() : null,
        provider: typeof metrics.provider === 'string' && metrics.provider.trim() ? metrics.provider.trim() : null,
        observed_at: observedAt, kind: 'event',
        input_tokens: input, output_tokens: output,
        cache_read_tokens: null, cache_write_tokens: null
      };
    }
  } finally { db?.close(); }
}
