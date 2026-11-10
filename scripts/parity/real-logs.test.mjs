import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, existsSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { environment, validateSnapshot } from './real-common.mjs';
import { compare, report } from './compare-real.mjs';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const executable = process.env.TL_REAL_LOGS_EXE ?? join(repo, 'app/rust/target/release/examples', process.platform === 'win32' ? 'real_logs.exe' : 'real_logs');
const read = file => readFileSync(file, 'utf8').trim().split('\n').map(line => JSON.parse(line));
const copy = (from, to) => { mkdirSync(dirname(to), { recursive: true }); copyFileSync(join(repo, from), to); };

test('production CLI and release StatsClient match on synthetic JSONL/zstd/SQLite WAL sources', { timeout: 300000 }, () => {
  assert.ok(existsSync(executable), 'build release example first');
  const root = mkdtempSync(join(tmpdir(), 'token-lens-d35a-'));
  const home = join(root, 'home');
  const out = join(root, 'output');
  mkdirSync(home);
  for (const [fixture, target] of [
    ['ingest-a.jsonl', '.claude/projects/a.jsonl'],
    ['ingest-codex.jsonl', '.codex/sessions/rollout-test.jsonl'],
    ['codex.jsonl.zst', '.codex/sessions/rollout-compressed.jsonl.zst'],
    ['kimi/.kimi/sessions/ledger.json', '.kimi/sessions/ledger.json'],
    ['pi/.pi/agent/sessions/p/ledger.jsonl', '.pi/agent/sessions/p/ledger.jsonl'],
    ['qwen/.qwen/usage/token-usage-ledger.jsonl', '.qwen/usage/token-usage-ledger.jsonl'],
  ]) copy(`test/fixtures/parity/${fixture}`, join(home, target));
  const privateText = 'D35_PRIVATE_BODY_MUST_NOT_EXPORT';
  appendFileSync(join(home, '.claude/projects/a.jsonl'), JSON.stringify({ sessionId: 'synthetic-private', timestamp: '2026-01-15T03:00:00Z', message: {
    id: 'private-body-test', model: 'unknown', content: privateText, usage: { input_tokens: privateText, output_tokens: 1 },
  } }) + '\n');
  // Leave committed rows in a live WAL while both readers run.
  const dbFile = join(home, '.local/share/opencode/opencode.db');
  mkdirSync(dirname(dbFile), { recursive: true });
  const writer = new DatabaseSync(dbFile);
  try {
    writer.exec('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0');
    writer.exec(readFileSync(join(repo, 'test/fixtures/parity/opencode/ledger.sql'), 'utf8'));
    assert.ok(existsSync(`${dbFile}-wal`));
    const before = [dbFile, `${dbFile}-wal`].map(file => readFileSync(file));
    const env = environment(join(root, 'control'), 'Asia/Shanghai', join(root, 'temp'));
    const args = ['--home', home, '--out', out, '--now', '2026-01-15T12:00:00.000Z', '--tz', 'Asia/Shanghai'];
    for (const [command, commands] of [
      [process.execPath, ['scripts/parity/real-logs-old.mjs', ...args]],
      [executable, args],
    ]) {
      const result = spawnSync(command, commands, { cwd: repo, env, encoding: 'utf8', timeout: 120000 });
      assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}\nsynthetic output: ${out}`);
    }
    for (const [index, file] of [dbFile, `${dbFile}-wal`].entries()) assert.deepEqual(readFileSync(file), before[index], 'input DB/WAL bytes unchanged');
    const left = read(join(out, 'old.jsonl')), right = read(join(out, 'new.jsonl'));
    const result = compare(left, right);
    writeFileSync(join(out, 'report.md'), report(result, left, right));
    writeFileSync(join(out, 'diff.jsonl'), result.diffs.map(row => JSON.stringify(row)).join('\n'));
    for (const file of ['old.jsonl', 'new.jsonl', 'report.md', 'diff.jsonl']) assert.ok(!readFileSync(join(out, file), 'utf8').includes(privateText), 'body must not be exported');
    assert.equal(result.diffs.length, 0, `synthetic differences: ${JSON.stringify(result.diffs.slice(0, 8))}; ${out}`);
    for (const source of ['claude', 'codex', 'opencode', 'kimi', 'pi', 'qwen']) assert.ok(result.overview.some(row => row.source === source && row.old.rows > 0));
    for (const side of [left, right]) {
      const run = side.find(row => row.type === 'run' && row.index === 1).expected;
      assert.deepEqual([run.inserted, run.updated], [0, 0]);
      const digests = side.find(row => row.fn === 'usage_digest').expected;
      assert.equal(digests.before, digests.after);
      assert.equal(side.filter(row => row.type === 'query' && row.range !== 'idempotence').length, 32);
      const total = side.filter(row => row.type === 'source_notes').reduce((n, row) => n + row.expected.bad_times, 0);
      assert.equal(total, run.counts.bad_times);
      const fields = side.filter(row => row.type === 'source_notes').reduce((n, row) => n + row.expected.bad_fields, 0);
      assert.ok(fields > 0);
      assert.equal(fields, run.counts.bad_fields);
    }
    console.log(`synthetic: ${out}; ${result.overview.reduce((n, row) => n + row.old.rows, 0)} rows, 32 queries, no differences`);
  } finally { writer.close(); }
});

test('snapshot configs cannot route discovery outside the supplied root', () => {
  const root = mkdtempSync(join(tmpdir(), 'token-lens-d35a-guard-'));
  const config = join(root, '.zcode/cli/config.json');
  mkdirSync(dirname(config), { recursive: true });
  writeFileSync(config, JSON.stringify({ storage: { sessionDbPath: resolve(root, '../outside.db') } }));
  assert.throws(() => validateSnapshot(root), /outside home/);
});
