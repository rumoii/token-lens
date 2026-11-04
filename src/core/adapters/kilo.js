import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeTimestamp } from './_lines.js';
import { isEmptyUsage, note, plus, tokenOf } from './_num.js';
import { projectFromCwd } from './_project.js';

/**
 * Kilo 21bcdec484a0 的逐请求消息。只读 session_message，
 * 不叠加 session 汇总或 message / part 兼容投影。
 * @param {string} filePath
 * @param {import('./_num.js').ParseNotes} [notes]
 */
export async function* parseKilo(filePath, notes) {
  if (!existsSync(filePath)) return;

  let db;
  try {
    db = new DatabaseSync(filePath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 3000');
    db.exec('PRAGMA query_only = ON');
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_message'").get()) return;

    const sessionColumns = new Set(db.prepare('PRAGMA table_info(session)').all().map(column => column.name));
    const sessionDirectory = sessionColumns.has('id') && sessionColumns.has('directory')
      ? db.prepare('SELECT directory FROM session WHERE id = ?')
      : null;

    const rows = db.prepare(`
      SELECT id, session_id, data FROM session_message
      WHERE type = 'assistant' ORDER BY time_created, id
    `).iterate();
    for (const row of rows) {
      let data;
      try {
        data = JSON.parse(row.data);
      } catch {
        note(notes, 'bad_lines');
        continue;
      }
      if (!data || typeof data !== 'object' || Array.isArray(data) || !row.id || !row.session_id) {
        note(notes, 'bad_lines');
        continue;
      }
      const tokens = data.tokens;
      if (!tokens || typeof tokens !== 'object') continue;
      // 写入的是 nonCachedInputTokens 与 visibleOutputTokens；推理单列。
      const input = tokenOf(tokens, ['input'], notes);
      const output = plus(tokenOf(tokens, ['output'], notes), tokenOf(tokens, ['reasoning'], notes));
      const read = tokenOf(tokens.cache, ['read'], notes);
      const write = tokenOf(tokens.cache, ['write'], notes);
      if (isEmptyUsage(input, output, read, write)) {
        note(notes, 'zero_usage');
        continue;
      }
      const observedAt = normalizeTimestamp(data.time?.created);
      if (!observedAt) {
        note(notes, 'bad_times');
        continue;
      }
      const model = typeof data.model?.id === 'string' ? data.model.id.trim() : '';
      yield {
        record_key: `kilo|${row.session_id}|${row.id}`,
        source: 'kilo',
        session_id: row.session_id,
        project_key: projectFromCwd(sessionDirectory?.get(row.session_id)?.directory),
        model: model && model !== 'legacy' ? model : null,
        provider: typeof data.model?.providerID === 'string' && data.model.providerID.trim() ? data.model.providerID : null,
        observed_at: observedAt,
        kind: 'event',
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: read,
        cache_write_tokens: write
      };
    }
  } finally {
    if (db) db.close();
  }
}
