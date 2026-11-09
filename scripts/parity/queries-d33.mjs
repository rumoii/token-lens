import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerQueries } from '../../src/core/db/read.js';
import { LedgerWriter } from '../../src/core/db/write.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { buildSummary, buildBreakdown, buildTimeseries, buildMatrix } from '../../src/core/api/v1/usage.js';
import { buildSessions, buildSessionDetail } from '../../src/core/api/v1/sessions.js';
import { buildSources, createDiscoveryService } from '../../src/core/api/v1/sources.js';
import { buildPricing } from '../../src/core/api/v1/pricing.js';
import { discoverAll } from '../../src/core/discovery.js';
import { runIngestion } from '../../src/core/ingest.js';
import { syntheticHome } from './isolation.mjs';
import { setup as setupB2 } from './ingest-b2.mjs';
import { setup as setupB3 } from './ingest-b3.mjs';
import { materialize } from './adapters-b3.mjs';

const fields = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens', 'cost_micros'];
const zones = [['UTC', 0], ['Asia/Shanghai', 480], ['America/New_York', -300], ['Asia/Katmandu', 345]];
const dimensions = ['model', 'source', 'project'];
const granularities = ['day', 'month', 'hour'];

function conserve(totals, rows, label) {
  // SQL sum ignores unknown columns. This compares the known contribution;
  // golden equality separately preserves every actual null in the responses.
  for (const field of fields) assert.equal(rows.reduce((sum, row) => sum + (row[field] ?? 0), 0), totals[field] ?? 0, `${label}: ${field}`);
}

export async function generateQueriesD33(output, now) {
  const rows = [{ type: 'context', now, tz: 'Asia/Shanghai' }];
  const emit = row => rows.push(row);
  let scenario = 'A';
  const query = (fn, args, expected) => emit({ type: 'query', scenario, fn, ...args, expected });
  const filters = [];
  const options = { from: '2026-01-14', to: '2026-01-16', source: 'claude', model: 'gpt-6.1-sol', project: '/synthetic/a' };
  for (let mask = 0; mask < 32; mask++) filters.push(Object.fromEntries(Object.entries(options).filter((_, i) => mask & (1 << i))));
  filters.push({ source: 'missing' }, { from: '2026-02-30' }, { from: '2026-1-010' });

  for (const [id, fixture] of [['A', 'records.json'], ['invalid', 'invalid-ended-at.json']]) {
    scenario = id;
    const records = JSON.parse(readFileSync(`test/fixtures/parity/queries/${fixture}`, 'utf8'));
    const db = openLedger(':memory:');
    try {
      const read = new LedgerQueries(db);
      const write = new LedgerWriter(db);
      const batch = write.ingestBatch(records, { priceOf: costOf });
      emit({ type: 'setup', scenario, fixture, expected: batch });
      const sql = id === 'A'
        ? `UPDATE usage_records SET active=0 WHERE record_key='inactive';
UPDATE usage_records SET source_file=CASE WHEN record_key='event' THEN 'synthetic-kept' WHEN record_key='cross-hour' THEN 'synthetic-gone' ELSE NULL END;
INSERT INTO legacy_records(origin_row_id,source,input_tokens) VALUES(1,'legacy',999);
INSERT INTO ingest_runs(started_at,finished_at,status,attempted,inserted,notes,counts) VALUES(1768478400,1768478400,'completed_with_anomalies',85,85,'["a","b","c","d","e","f"]','{"bad_times":2}');`
        : '';
      db.exec(sql);
      emit({ type: 'sql', scenario, sql });
      for (const [tz, offsetMinutes] of zones) {
        process.env.TZ = tz;
        for (const params of id === 'A' ? filters : [{}]) {
          const p = { ...params, tz };
          const filter = { from: params.from || '', to: params.to || '', source: params.source || null, model: params.model || null, project: params.project || null, offsetMinutes };
          const totals = read.totals(filter);
          query('read.totals', { filter }, totals);
          if (id === 'A') query('summary', { params: p, offsetMinutes }, buildSummary(read, p));
          for (const by of dimensions) {
            const groups = read.breakdown(by, filter);
            conserve(totals, groups, `${id}/breakdown/${by}`);
            query('read.breakdown', { by, filter }, groups);
            query('breakdown', { params: { ...p, by }, offsetMinutes }, buildBreakdown(read, { ...p, by }));
          }
          for (const granularity of granularities) {
            const series = read.timeseries(granularity, filter);
            if (id === 'A') conserve(totals, [...series.points, ...(series.unallocated ? [series.unallocated] : [])], 'timeseries');
            query('read.timeseries', { granularity, filter }, series);
            query('timeseries', { params: { ...p, granularity }, offsetMinutes }, buildTimeseries(read, { ...p, granularity }));
            for (const by of dimensions) {
              const matrix = read.timeseriesGrouped(granularity, by, filter);
              if (id === 'A') conserve(totals, [...matrix.rows, ...(matrix.unallocated ? [matrix.unallocated] : [])], 'matrix');
              query('read.matrix', { granularity, by, filter }, matrix);
              query('matrix', { params: { ...p, granularity, by }, offsetMinutes }, buildMatrix(read, { ...p, granularity, by }));
            }
          }
        }
        if (id === 'A') {
          const baseline = read.sessions({ limit: 200 }).items.map(row => [row.source, row.session_id]);
          for (const limit of [1, 2, undefined, 0, 999]) {
            let cursor = null;
            const seen = [];
            do {
              const params = { tz, ...(limit === undefined ? {} : { limit }), cursor };
              const page = buildSessions(read, params);
              const raw = read.sessions({ limit, cursor, filter: { offsetMinutes } });
              query('read.sessions', { params, offsetMinutes }, raw);
              query('sessions', { params, offsetMinutes }, page);
              seen.push(...page.items.map(row => [row.source, row.session_id]));
              cursor = page.next_cursor;
            } while (cursor);
            assert.deepEqual(seen, baseline, `all pages, limit=${limit}`);
          }
          for (const cursor of ['@@@', 'LTE=', 'MS41', 'YWJj', 'NTA']) {
            query('sessions', { params: { tz, limit: 2, cursor }, offsetMinutes }, buildSessions(read, { tz, limit: 2, cursor }));
          }
          for (const [source, session_id] of [['claude', 'mixed'], ['claude', 'page-0'], ['dsh', 'tod-weekly'], ['missing', 'missing']]) {
            for (const granularity of ['hour', 'day']) {
              const params = { tz, source, session_id, granularity };
              query('read.session_detail', { params, offsetMinutes }, read.sessionDetail({ source, sessionId: session_id, granularity, offsetMinutes }));
              query('session_detail', { params, offsetMinutes }, buildSessionDetail(read, params));
            }
          }
        }
      }
      process.env.TZ = 'Asia/Shanghai';
      query('read.legacy_count', {}, read.legacyCount());
      query('read.source_status', {}, read.sourceStatus());
      query('read.source_checks', {}, Object.fromEntries(read.sourceChecks({ now })));
      query('read.source_files', {}, read.sourceFiles());
      query('read.model_price_marks', {}, read.modelPriceMarks());
      query('read.last_run', {}, read.lastRun());
      query('sources', {}, buildSources(read, { now: new Date(now), exists: path => path === 'synthetic-kept' }));
      query('pricing', {}, buildPricing(read));
      if (id === 'A') {
        for (const sql of [
          `UPDATE ingest_runs SET status='',notes='[1,true,null,{"x":1},["a",null],false]',counts='[]';`,
          `UPDATE ingest_runs SET status='failed',notes='not-json',counts='{bad';`,
          `UPDATE ingest_runs SET notes='{"text":"not an array"}',counts='null';`,
        ]) {
          db.exec(sql); emit({ type: 'sql', scenario, sql });
          query('read.last_run', {}, read.lastRun());
          query('sources', {}, buildSources(read, { now: new Date(now), exists: path => path === 'synthetic-kept' }));
        }
      }
    } finally { db.close(); }
  }

  for (const value of [0, 1, 50, 9007199254740991]) query('cursor.encode', { value }, Buffer.from(String(value), 'utf8').toString('base64'));
  for (const value of [null, '', 'MA==', 'MQ==', 'NTA=', 'OTAwNzE5OTI1NDc0MDk5MQ==', 'N!T@A', 'NTA', '-___', '+///', 'LTE=', 'MS41', 'YWJj']) {
    const n = value ? Number(Buffer.from(value, 'base64').toString('utf8')) : 0;
    query('cursor.decode', { value }, Number.isInteger(n) && n >= 0 ? n : 0);
  }

  scenario = 'B';
  // Each process reaches discovery/ingestion only after this isolation entry.
  const { root, home } = syntheticHome();
  const files = [...setupB2, ...setupB3];
  const dataDir = join(root, 'data');
  try {
    emit({ type: 'setup_b', scenario, files });
    for (const entry of files) {
      if (entry.input.endsWith('.sql')) materialize(home, { source: entry.source, file: entry.target, kind: 'seed', seed: entry.input });
      else { const target = join(home, entry.target); mkdirSync(dirname(target), { recursive: true }); copyFileSync(entry.input, target); }
    }
    for (let index = 0; index < 2; index++) {
      const result = await runIngestion({ dataDir }); result.durationMs = '<volatile>';
      emit({ type: 'run', scenario, index, expected: result });
    }
    const ledger = new Ledger(join(dataDir, 'ledger.db'));
    try {
      const sources = buildSources(ledger.read, { now: new Date(now), exists: existsSync });
      assert.equal(sources.sources.length, 27);
      assert.ok(sources.sources.every(source => source.limits.length > 0));
      query('sources', {}, sources);
      query('pricing', {}, buildPricing(ledger.read));
      const discover = createDiscoveryService(() => discoverAll());
      query('discovery', {}, discover());
      query('discovery', { fresh: true }, discover({ fresh: true }));
    } finally { ledger.close(); }
  } finally {
    // Only the root returned to this invocation by syntheticHome may be removed.
    assert.equal(dirname(resolve(root)), realpathSync(tmpdir()));
    assert.equal(realpathSync(root), resolve(root));
    assert.ok(basename(root).startsWith('token-lens-d31-ingest-'));
    rmSync(root, { recursive: true, force: true });
  }
  process.env.TZ = 'Asia/Shanghai';
  writeFileSync(join(output, 'queries-d33.jsonl'), rows.map(row => JSON.stringify(row)).join('\n') + '\n');
  console.log(`queries-d33: ${rows.length} rows, ${filters.length} filters, 4 offsets, 3 granularities, 3 dimensions, 27 sources`);
}
