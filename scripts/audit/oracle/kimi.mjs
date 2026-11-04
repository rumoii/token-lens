import { basename, dirname } from 'node:path';
import { count, entry, jsonLines, readFiles } from './common.mjs';

// Kimi Code wire: sessions/<workdir>/session_<id>/agents/<agent>/wire.jsonl.
// Every usage.record is one model call, for the main agent and for sub-agents.
export async function oracle(options = {}) {
  return readFiles('kimi', options, async (file, issues) => {
    const entries = [], cross_checks = [];
    const sessionDir = basename(dirname(dirname(dirname(file))));
    const session = sessionDir.startsWith('session_') ? sessionDir.slice('session_'.length) : sessionDir;
    if (session === sessionDir) issues.push({ type: 'session_dir_without_prefix', file, session_id: session });
    const pending = [];
    for await (const { value: row, line } of jsonLines(file, issues)) {
      if (row.type === 'usage.record') {
        const usage = row.usage;
        if (!usage || typeof usage !== 'object') { issues.push({ type: 'usage_without_object', file, line }); continue; }
        const tokens = {
          input: count(usage.inputOther), output: count(usage.output),
          cache_read: count(usage.inputCacheRead), cache_write: count(usage.inputCacheCreation)
        };
        const observed = Number.isFinite(row.time) ? row.time : null;
        entries.push(entry('kimi', session, JSON.stringify([file, line]), file, line, observed, tokens,
          { model: row.model ?? null, agent: row.agentId ?? null, scope: row.usageScope ?? null }));
        pending.push({ line, time: row.time, agent: row.agentId, tokens });
      } else if (row.type === 'token_counting.measured') {
        // The client measures the call's total right after recording it; the four
        // parts must add up to it when they do not overlap.
        const index = pending.findIndex(p => p.time === row.time && p.agent === row.agentId);
        if (index < 0) continue;
        const [usage] = pending.splice(index, 1);
        const parts = Object.values(usage.tokens);
        const sum = parts.includes(null) ? null : parts.reduce((a, b) => a + b, 0);
        cross_checks.push({ type: 'measured_total', file, line: usage.line, sum, measured: row.tokens, ok: sum === row.tokens });
      }
    }
    for (const p of pending) cross_checks.push({ type: 'measured_missing', file, line: p.line, ok: null });
    return { entries, cross_checks };
  });
}
