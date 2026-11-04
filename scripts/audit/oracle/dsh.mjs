import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { aggregate, count, discover, entry, time } from './common.mjs';

export async function oracle(options = {}) {
  const files = options.files ?? discover('dsh', options.home);
  const latest = new Map(), issues = [], duplicates = [];
  for (const file of files) {
    try {
      const row = JSON.parse(readFileSync(file, 'utf8'));
      const usage = row.record?.rows?.tokenUsage?.val?.totals;
      if (!usage || typeof usage !== 'object') { issues.push({ type: 'missing_totals', file }); continue; }
      const identity = row.record.identity;
      const session = basename(file, '.json').replace(/^session-/, '');
      const snapshot = entry('dsh', session, session, file, 1, identity?.createdAt, {
        input: count(usage.uncachedInputTokens), output: count(usage.outputTokens),
        cache_read: count(usage.cacheReadTokens), cache_write: count(usage.cacheWriteTokens)
      }, { totals: usage, identity, ended_at: row.record.rows.timeContext?.val?.lastMessageTime ?? null });
      snapshot.ended_at = time(snapshot.raw.ended_at);
      const prior = latest.get(session);
      if (!prior || (snapshot.ended_at ?? '') > (prior.ended_at ?? '') ||
          (snapshot.ended_at === prior.ended_at && file > prior.file)) {
        if (prior) duplicates.push({ type: 'older_cumulative', kept: snapshot, dropped: prior });
        latest.set(session, snapshot);
      } else duplicates.push({ type: 'older_cumulative', kept: prior, dropped: snapshot });
    } catch (error) { issues.push({ type: 'read_failed', file, message: error.message }); }
  }
  const entries = [...latest.values()];
  return { source: 'dsh', files, entries, sessions: aggregate(entries), duplicates, issues,
    cross_checks: entries.map(row => ({ session_id: row.session_id, file: row.file, line: 1,
      basis: 'record.rows.tokenUsage.val.totals', totals: row.raw.totals })) };
}
