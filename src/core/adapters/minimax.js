import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

/**
 * MiniMax Code v2/sqlite/runtime-state.sqlite 的逐请求用量。
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes]
 */
export async function* parseMinimax(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'local_runtime_token_usage'").get()) return;

    const sessionColumns = new Set(db.prepare('PRAGMA table_info(local_runtime_sessions)').all().map(column => column.name));
    const sessionWorkspace = sessionColumns.has('session_id') && sessionColumns.has('workspace_dir')
      ? db.prepare('SELECT workspace_dir FROM local_runtime_sessions WHERE session_id = ?')
      : null;

    const rows = db.prepare(`
      SELECT id, session_id, model, ts, input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens
      FROM local_runtime_token_usage ORDER BY ts, id
    `).iterate();
    for (const row of rows) {
      if (!row.id || typeof row.session_id !== 'string' || !row.session_id.trim()) {
        note(notes, 'bad_lines');
        continue;
      }
      const input = tokenOf(row, ['input_tokens'], notes);
      // pi 系 usage 的 output 已含推理，不能再加 reasoning。
      const output = tokenOf(row, ['output_tokens'], notes);
      const read = tokenOf(row, ['cache_read_tokens'], notes);
      const write = tokenOf(row, ['cache_write_tokens'], notes);
      if (isEmptyUsage(input, output, read, write)) {
        note(notes, 'zero_usage');
        continue;
      }
      const observedAt = normalizeTimestamp(row.ts);
      if (!observedAt) {
        note(notes, 'bad_times');
        continue;
      }
      const model = typeof row.model === 'string' ? row.model.trim() : '';
      yield {
        record_key: `minimax|${row.session_id}|${row.id}`,
        source: 'minimax',
        session_id: row.session_id,
        project_key: projectFromCwd(sessionWorkspace?.get(row.session_id)?.workspace_dir),
        model: model || null,
        provider: null,
        observed_at: observedAt,
        kind: 'event',
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: read,
        cache_write_tokens: write,
        cache_creation_tokens: write
      };
    }
  } finally {
    if (db) db.close();
  }
}
