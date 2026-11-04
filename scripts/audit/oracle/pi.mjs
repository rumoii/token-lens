import { count, entry, jsonLines, readFiles, sessionFromFile } from './common.mjs';

export async function oracle(options = {}) {
  const result = await readFiles('pi', options, async (file, issues) => {
    const entries = [];
    let session = null;
    for await (const { value: row, line } of jsonLines(file, issues)) {
      if (row.type === 'session') { session = row.id ?? null; continue; }
      const usage = row.message?.usage;
      if (!usage || typeof usage !== 'object') continue;
      if (session === null) {
        session = sessionFromFile(file).split('_').at(-1);
        issues.push({ type: 'session_from_filename', file, line, session_id: session });
      }
      const id = row.message.id ?? row.id ?? `file:${file}:${line}`;
      entries.push(entry('pi', session, JSON.stringify([session, id]), file, line, row.timestamp ?? row.message.timestamp, {
        input: count(usage.input), output: count(usage.output),
        cache_read: count(usage.cacheRead), cache_write: count(usage.cacheWrite)
      }, { id, usage, role: row.message.role ?? null }));
    }
    return { entries };
  });
  // Short entry ids are scoped to a session. Cross-session matches are evidence
  // for investigating copied history, not grounds to discard a billed request.
  const candidates = new Map();
  for (const row of result.entries) {
    const key = JSON.stringify([row.raw.id, row.observed_at, row.input, row.output, row.cache_read, row.cache_write]);
    const rows = candidates.get(key) || [];
    rows.push(row);
    candidates.set(key, rows);
  }
  result.copy_candidates = [...candidates.values()].filter(rows => new Set(rows.map(r => r.session_id)).size > 1);
  return result;
}
