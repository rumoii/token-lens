import { createReadStream, existsSync, globSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

export const fields = ['input', 'output', 'cache_read', 'cache_write'];
export const locations = {
  claude: ['.claude/projects', '**/*.jsonl'],
  codex: ['.codex/sessions', '**/rollout-*.{jsonl,jsonl.zst}'],
  qwen: ['.qwen/usage', '*-usage-*.jsonl'],
  dsh: ['.dsh/storages/session_projcache/sessions', '*.json'],
  pi: ['.pi/agent/sessions', '**/*.jsonl'],
  kimi: ['.kimi-code/sessions', '*/*/agents/*/wire.jsonl']
};

export function discover(source, home = homedir()) {
  const [directory, pattern] = locations[source];
  const root = join(home, directory);
  if (!existsSync(root)) return [];
  return globSync(pattern, { cwd: root }).map(file => resolve(root, file)).sort();
}

export function count(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

export function time(value) {
  if (value == null || value === '') return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

export function subtract(input, ...parts) {
  if (input === null || parts.includes(null)) return null;
  return count(input - parts.reduce((sum, part) => sum + part, 0));
}

export function sessionFromFile(file) {
  return basename(file).replace(/\.jsonl(?:\.zst)?$|\.json$/i, '');
}

// Parse physical lines, including blanks in the line counter. A malformed line
// remains an explicit issue; a failed file never contributes partial entries.
export async function* jsonLines(file, issues) {
  const input = file.endsWith('.zst')
    ? [zstdDecompressSync(readFileSync(file)).toString('utf8')]
    : createReadStream(file, { encoding: 'utf8' });
  const { Readable } = await import('node:stream');
  const stream = Array.isArray(input) ? Readable.from(input) : input;
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let number = 0;
  try {
    for await (const text of lines) {
      number++;
      if (!text.trim()) continue;
      let value;
      try { value = JSON.parse(text); }
      catch { issues.push({ type: 'bad_json', file, line: number }); continue; }
      if (!value || typeof value !== 'object' || Array.isArray(value)) {
        issues.push({ type: 'not_an_object', file, line: number });
        continue;
      }
      yield { value, line: number };
    }
  } finally {
    lines.close();
    stream.destroy();
  }
}

export function aggregate(entries) {
  const groups = new Map();
  for (const entry of entries) {
    const key = JSON.stringify([entry.source, entry.session_id]);
    let row = groups.get(key);
    if (!row) {
      row = { source: entry.source, session_id: entry.session_id, records: 0,
        unknown_records: 0, unknown: Object.fromEntries(fields.map(f => [f, 0])),
        ...Object.fromEntries(fields.map(f => [f, null])) };
      groups.set(key, row);
    }
    row.records++;
    if (fields.some(f => entry[f] == null)) row.unknown_records++;
    for (const field of fields) {
      if (entry[field] == null) row.unknown[field]++;
      else row[field] = (row[field] ?? 0) + entry[field];
    }
  }
  return [...groups.values()].sort((a, b) => JSON.stringify(a.session_id).localeCompare(JSON.stringify(b.session_id)));
}

export function entry(source, session_id, identity, file, line, observed_at, tokens, raw) {
  return { source, session_id: session_id ?? null, identity, file, line,
    observed_at: time(observed_at), ...tokens, raw };
}

// Last snapshot within one file; across files, the earliest file owns an event.
// Identity is supplied by each source, independently of its token values.
export function finish(source, files, entries, issues, cross_checks = []) {
  const starts = new Map();
  const local = new Map();
  const duplicates = [];
  for (const row of entries) {
    if (row.observed_at) {
      const prior = starts.get(row.file);
      if (!prior || row.observed_at < prior) starts.set(row.file, row.observed_at);
    } else issues.push({ type: 'missing_or_invalid_time', file: row.file, line: row.line, identity: row.identity });
    const key = JSON.stringify([row.file, row.identity]);
    if (local.has(key)) duplicates.push({ type: 'snapshot', kept: row, dropped: local.get(key) });
    local.set(key, row);
  }
  const byIdentity = new Map();
  for (const row of local.values()) {
    const candidates = byIdentity.get(row.identity) || [];
    candidates.push(row);
    byIdentity.set(row.identity, candidates);
  }
  const kept = [];
  for (const candidates of byIdentity.values()) {
    candidates.sort((a, b) => (starts.get(a.file) ?? '').localeCompare(starts.get(b.file) ?? '') || a.file.localeCompare(b.file));
    kept.push(candidates[0]);
    for (const copy of candidates.slice(1)) duplicates.push({ type: 'cross_file_copy', kept: candidates[0], dropped: copy });
  }
  return { source, files, entries: kept, sessions: aggregate(kept), duplicates, issues, cross_checks };
}

export async function readFiles(source, options, parse) {
  const files = options.files ?? discover(source, options.home);
  const entries = [], issues = [], cross_checks = [];
  for (const file of files) {
    try {
      const result = await parse(file, issues);
      entries.push(...result.entries);
      cross_checks.push(...(result.cross_checks || []));
    } catch (error) { issues.push({ type: 'read_failed', file, message: error.message }); }
  }
  return finish(source, files, entries, issues, cross_checks);
}
