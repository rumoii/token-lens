import { mkdirSync, existsSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { parseArgs, environment, ledgerRows, usageDigest, safeNotes, writeJsonl, mirrorSource, validateSnapshot, copySeed } from './real-common.mjs';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const mode = process.env.TL_PARITY_OLD_MODE;

// Module loading occurs only after the child receives the isolated environment.
async function exportOld(options) {
  const { discoverAll } = await import('../../src/core/discovery.js');
  const { Ledger } = await import('../../src/core/db/ledger.js');
  const { buildSummary, buildBreakdown, buildTimeseries, buildMatrix } = await import('../../src/core/api/v1/usage.js');
  const { buildSessions } = await import('../../src/core/api/v1/sessions.js');
  const { buildSources } = await import('../../src/core/api/v1/sources.js');
  const { offsetMinutesOf } = await import('../../src/core/api/v1/common.js');
  const { adapters } = await import('../../src/core/adapters/index.js');
  const { newNotes } = await import('../../src/core/adapters/_num.js');
  const discovered = discoverAll();
  const ledger = new Ledger(join(options.out, 'old/ledger.db'));
  try {
    const db = new DatabaseSync(join(options.out, 'old/ledger.db'), { readOnly: true });
    let tables;
    try { tables = ledgerRows(db); } finally { db.close(); }
    const { seed, ...metadata } = options;
    const rows = [{ type: 'context', format: 1, complete: true, sources: Object.keys(discovered).sort(), ...metadata }, ...tables];
    for (const [index, run] of tables.filter(row => row.table === 'ingest_runs').slice(-2).entries()) {
      const expected = { ...run.expected, fileCount: Object.values(discovered).reduce((n, files) => n + files.length, 0), anomalies: run.expected.notes?.length ?? 0, durationMs: 0 };
      rows.push({ type: 'run', index, expected });
    }
    const offset = offsetMinutesOf(options.tz);
    const local = new Date(Date.now() + offset * 60000);
    const today = local.toISOString().slice(0, 10);
    const monday = new Date(local.getTime() - ((local.getUTCDay() + 6) % 7) * 86400000).toISOString().slice(0, 10);
    const ranges = [{ range: 'all', from: '', to: '' }, { range: 'month', from: today.slice(0, 8) + '01', to: today }, { range: 'week', from: monday, to: today }, { range: 'today', from: today, to: today }];
    for (const { range, from, to } of ranges) {
      const params = { tz: options.tz, from, to };
      for (const [fn, call] of [ ['summary', () => buildSummary(ledger.read, params)], ['timeseries', () => buildTimeseries(ledger.read, { ...params, granularity: 'day' })], ['matrix', () => buildMatrix(ledger.read, { ...params, granularity: 'day', by: 'model' })], ['sessions', () => buildSessions(ledger.read, { ...params, limit: 50 })], ['sources', () => buildSources(ledger.read)] ]) {
        const expected = call();
        if (fn === 'sources' && expected.last_run) expected.last_run.anomalies = expected.last_run.anomalies.map(note => safeNotes(JSON.stringify([note]))[0]);
        rows.push({ type: 'query', range, fn, expected });
      }
      for (const by of ['source', 'model', 'project']) rows.push({ type: 'query', range, fn: 'breakdown', by, expected: buildBreakdown(ledger.read, { ...params, by }) });
    }
    const probes = [];
    for (const [source, files] of Object.entries(discovered)) {
      let bad_fields = 0, bad_times = 0;
      for (const file of files) {
        const notes = newNotes();
        try {
          for await (const record of adapters[source](file, notes)) if (record && typeof record === 'object' && !record.observed_at) notes.bad_times++;
          bad_fields += notes.bad_fields; bad_times += notes.bad_times;
        } catch { /* The production ingest discards notes for a failed file. */ }
      }
      const home = join(options.out, 'probe-inputs', source);
      mirrorSource(options.home, files, home, source);
      probes.push({ source, home, fileCount: files.length });
      rows.push({ type: 'source_notes', source, expected: { bad_fields, bad_times } });
    }
    const first = JSON.parse(readFileSync(join(options.out, 'old-first.json'), 'utf8'));
    rows.push({ type: 'query', range: 'idempotence', fn: 'usage_digest', expected: { before: first, after: usageDigest(tables) } });
    writeFileSync(join(options.out, 'context.json'), JSON.stringify({ ...options, offset, ranges, probes }));
    writeJsonl(join(options.out, 'old.jsonl'), rows);
  } finally { ledger.close(); }
}

try {
  if (mode === 'export') await exportOld(JSON.parse(process.env.TL_PARITY_OPTIONS));
  else {
    const options = parseArgs();
    validateSnapshot(options.home);
    if (existsSync(join(options.out, 'old')) || existsSync(join(options.out, 'old.jsonl'))) throw Error('old output already exists');
    mkdirSync(options.out, { recursive: true });
    if (options.seed) options.seed_sha256 = copySeed(options.seed, join(options.out, 'old'));
    const env = environment(options.home, options.tz, join(options.out, 'temp/old'));
    env.TL_PARITY_NOW = options.now;
    const run = (args, extra = {}) => {
      const child = spawnSync(process.execPath, ['--import', new URL('./real-freeze.mjs', import.meta.url).href, ...args], { cwd: repo, env: { ...env, ...extra }, encoding: 'utf8', timeout: 300000, maxBuffer: 32 * 1024 * 1024 });
      // CLI warnings can contain source text; never forward stdout/stderr.
      if (child.status !== 0 || child.error) throw Error('old subprocess failed');
    };
    for (let index = 0; index < 2; index++) {
      run(['bin/lens.js', 'collect', '--data-dir', join(options.out, 'old')]);
      if (index === 0) {
        const db = new DatabaseSync(join(options.out, 'old/ledger.db'), { readOnly: true });
        try { writeFileSync(join(options.out, 'old-first.json'), JSON.stringify(usageDigest(ledgerRows(db)))); } finally { db.close(); }
      }
    }
    run([fileURLToPath(import.meta.url)], { TL_PARITY_OLD_MODE: 'export', TL_PARITY_OPTIONS: JSON.stringify(options) });
    console.log('old: two production collections and export complete');
  }
} catch { console.error('old: failed; source content suppressed'); process.exitCode = 2; }
