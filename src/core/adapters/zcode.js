import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

/**
 * ZCode 3c5b22764937 的逐请求用量；不叠加 turn_usage 等汇总。
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes]
 */
export async function* parseZcode(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'model_usage'").get()) return;

    const sessionColumns = new Set(db.prepare('PRAGMA table_info(session)').all().map(column => column.name));
    const sessionDirectory = sessionColumns.has('id') && sessionColumns.has('directory')
      ? db.prepare('SELECT directory FROM session WHERE id = ?')
      : null;

    const rows = db.prepare(`
      SELECT id, session_id, model_id, provider_id, started_at,
        input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens
      FROM model_usage ORDER BY started_at, id
    `).iterate();
    for (const row of rows) {
      if (typeof row.id !== 'string' || !row.id.trim()) {
        note(notes, 'bad_lines');
        continue;
      }
      let input = tokenOf(row, ['input_tokens'], notes);
      const output = tokenOf(row, ['output_tokens'], notes);
      const read = tokenOf(row, ['cache_read_input_tokens'], notes);
      const write = tokenOf(row, ['cache_creation_input_tokens'], notes);
      // ModelUsage.inputTokens 已含缓存读写，outputTokens 已含推理。
      if (input !== null) {
        input -= (read ?? 0) + (write ?? 0);
        if (input < 0) {
          input = null;
          note(notes, 'bad_fields');
        }
      }
      if (isEmptyUsage(input, output, read, write)) {
        note(notes, 'zero_usage');
        continue;
      }
      const observedAt = normalizeTimestamp(row.started_at);
      if (!observedAt) {
        note(notes, 'bad_times');
        continue;
      }
      const session = typeof row.session_id === 'string' && row.session_id.trim() ? row.session_id : null;
      const model = typeof row.model_id === 'string' ? row.model_id.trim() : '';
      yield {
        record_key: `zcode|${session ?? '-'}|${row.id}`,
        source: 'zcode',
        session_id: session,
        project_key: projectFromCwd(session === null ? null : sessionDirectory?.get(session)?.directory),
        model: model || null,
        provider: typeof row.provider_id === 'string' && row.provider_id.trim() ? row.provider_id : null,
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
