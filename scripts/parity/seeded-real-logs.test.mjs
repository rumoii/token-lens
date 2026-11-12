import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, writeFileSync, existsSync, unlinkSync, appendFileSync, cpSync } from 'node:fs';
import { tmpdir, userInfo } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { environment, parseArgs } from './real-common.mjs';
import { compare, report } from './compare-real.mjs';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const executable = process.env.TL_REAL_LOGS_EXE ?? join(repo, 'app/rust/target/release/examples', process.platform === 'win32' ? 'real_logs.exe' : 'real_logs');
const now = '2026-01-15T12:00:00.000Z';
const read = file => readFileSync(file, 'utf8').trim().split('\n').map(JSON.parse);
const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
function setup() {
  const root = mkdtempSync(join(tmpdir(), 'token-lens-d42-'));
  const home = join(root, 'home');
  mkdirSync(home);
  return { root, home, env: environment(join(root, 'control'), 'Asia/Shanghai', join(root, 'temp')) };
}
function invoke(command, home, out, env, seed) {
  const args = ['--home', home, '--out', out, '--now', now, '--tz', 'Asia/Shanghai'];
  if (seed !== undefined) args.push('--seed', seed);
  return spawnSync(command, command === process.execPath ? ['scripts/parity/real-logs-old.mjs', ...args] : args,
    { cwd: repo, env, encoding: 'utf8', timeout: 180000 });
}
function ok(result) { assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`); }

test('seed preserves pruned history, includes uncheckpointed WAL, retains historical runs and matches both production paths', { timeout: 300000 }, () => {
  assert.ok(existsSync(executable), 'build release example first');
  const { root, home, env } = setup();
  for (const [fixture, target] of [
    ['ingest-a.jsonl', '.claude/projects/a.jsonl'],
    ['ingest-codex.jsonl', '.codex/sessions/rollout-test.jsonl'],
    ['codex.jsonl.zst', '.codex/sessions/rollout-compressed.jsonl.zst'],
    ['kimi/.kimi/sessions/ledger.json', '.kimi/sessions/ledger.json'],
    ['pi/.pi/agent/sessions/p/ledger.jsonl', '.pi/agent/sessions/p/ledger.jsonl'],
    ['qwen/.qwen/usage/token-usage-ledger.jsonl', '.qwen/usage/token-usage-ledger.jsonl'],
  ]) {
    const targetFile = join(home, target);
    mkdirSync(dirname(targetFile), { recursive: true });
    copyFileSync(join(repo, 'test/fixtures/parity', fixture), targetFile);
  }
  const logDb = join(home, '.local/share/opencode/opencode.db');
  mkdirSync(dirname(logDb), { recursive: true });
  const logWriter = new DatabaseSync(logDb);
  let seedWriter;
  try {
    logWriter.exec('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0');
    logWriter.exec(readFileSync(join(repo, 'test/fixtures/parity/opencode/ledger.sql'), 'utf8'));
    assert.ok(readFileSync(`${logDb}-wal`).length > 0);
    const initial = join(root, 'initial');
    ok(invoke(process.execPath, home, initial, env));
    const seed = join(initial, 'old');
    seedWriter = new DatabaseSync(join(seed, 'ledger.db'));
    seedWriter.exec('PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA wal_autocheckpoint=0');
    const history = seedWriter.prepare('SELECT record_key FROM usage_records WHERE source = ?').all('kimi');
    assert.ok(history.length > 0);
    // A committed change existing only in the seed WAL must survive both copies.
    seedWriter.exec("UPDATE usage_records SET project_key = 'd42-wal-marker' WHERE source = 'kimi'");
    assert.ok(readFileSync(join(seed, 'ledger.db-wal')).length > 0);
    const original = ['ledger.db', 'ledger.db-wal', 'ledger.db-shm'].map(name => readFileSync(join(seed, name)));
    writeFileSync(join(seed, 'must-not-copy.txt'), 'private sentinel');
    // Delete an entire file and prune one still-discoverable file: both histories remain active.
    unlinkSync(join(home, '.kimi/sessions/ledger.json'));
    const claude = join(home, '.claude/projects/a.jsonl');
    const lines = readFileSync(claude, 'utf8').trim().split('\n');
    writeFileSync(claude, lines.slice(1).join('\n') + '\n');
    appendFileSync(claude, JSON.stringify({ sessionId: 'd42-new', timestamp: now, message: {
      id: 'd42-new', model: 'unknown', usage: { input_tokens: 9, output_tokens: 2 },
    } }) + '\n');
    const out = join(root, 'output');
    for (const command of [process.execPath, executable]) ok(invoke(command, home, out, env, seed));
    const left = read(join(out, 'old.jsonl')), right = read(join(out, 'new.jsonl'));
    const result = compare(left, right);
    writeFileSync(join(out, 'report.md'), report(result, left, right));
    writeFileSync(join(out, 'diff.jsonl'), result.diffs.map(row => JSON.stringify(row)).join('\n'));
    assert.deepEqual(result.diffs, [], out);
    for (const source of ['claude', 'codex', 'opencode', 'kimi', 'pi', 'qwen']) assert.ok(result.overview.some(row => row.source === source && row.old.rows > 0));
    for (const side of [left, right]) {
      assert.equal(side[0].seed_sha256, hash(join(seed, 'ledger.db')));
      assert.equal(side.filter(row => row.type === 'run').length, 2);
      assert.equal(side.filter(row => row.table === 'ingest_runs').length, 4);
      for (const { record_key } of history) {
        const row = side.find(row => row.table === 'usage_records' && row.expected.record_key === record_key).expected;
        assert.equal(row.active, 1);
        assert.equal(row.project_key, 'd42-wal-marker');
      }
      const second = side.find(row => row.type === 'run' && row.index === 1).expected;
      assert.deepEqual([second.inserted, second.updated], [0, 0]);
      assert.ok(second.counts.vanished > 0);
      const digest = side.find(row => row.fn === 'usage_digest').expected;
      assert.equal(digest.before, digest.after);
    }
    for (const [index, name] of ['ledger.db', 'ledger.db-wal', 'ledger.db-shm'].entries()) assert.deepEqual(readFileSync(join(seed, name)), original[index], 'seed bytes unchanged');
    for (const side of ['old', 'new']) assert.ok(!existsSync(join(out, side, 'must-not-copy.txt')));
    // Different physical seed, same usage: comparator must reject the seed hash itself.
    const other = join(root, 'other-seed');
    cpSync(seed, other, { recursive: true });
    const otherDb = new DatabaseSync(join(other, 'ledger.db'));
    otherDb.exec('CREATE TABLE d42_marker (value TEXT)');
    otherDb.close();
    const mismatch = join(root, 'mismatch');
    ok(invoke(process.execPath, home, mismatch, env, seed));
    ok(invoke(executable, home, mismatch, env, other));
    assert.throws(() => compare(read(join(mismatch, 'old.jsonl')), read(join(mismatch, 'new.jsonl'))), /seed.*hash/i);
    console.log(`D42 synthetic: ${root}`);
  } finally { seedWriter?.close(); logWriter.close(); }
});

test('both exporters reject unsafe seeds before creating output, without opening protected paths', () => {
  const { root, home, env } = setup();
  const seed = join(root, 'seed');
  mkdirSync(seed);
  writeFileSync(join(seed, 'ledger.db'), 'not opened during preflight');
  const missing = join(root, 'missing-db');
  mkdirSync(missing);
  const linked = join(root, 'seed-link');
  const link = spawnSync('pwsh', ['-NoProfile', '-Command', `New-Item -ItemType Junction -Path '${linked}' -Target '${seed}' | Out-Null`], { encoding: 'utf8' });
  if (process.platform === 'win32') assert.equal(link.status, 0, link.stderr);
  const protectedSeed = join(userInfo().homedir, '.token-lens');
  for (const command of [process.execPath, executable]) {
    for (const [name, input, output] of [
      ['relative', 'relative-seed', join(root, 'relative-out')],
      ['missing', missing, join(root, 'missing-out')],
      ['equal', seed, seed],
      ['inside-seed', seed, join(seed, 'out')],
      ['contains-seed', seed, root],
      ['protected', protectedSeed, join(root, 'protected-out')],
      ['protected-child', join(protectedSeed, 'child'), join(root, 'protected-child-out')],
      ...(process.platform === 'win32' ? [['link', linked, join(root, 'link-out')]] : []),
    ]) {
      const existed = existsSync(output);
      assert.throws(() => parseArgs(['--home', home, '--out', output, '--now', now, '--tz', 'Asia/Shanghai', '--seed', input]), name);
      const result = invoke(command, home, output, env, input);
      assert.notEqual(result.status, 0, name);
      assert.equal(result.error, undefined, name);
      if (!existed) assert.ok(!existsSync(output), name);
      assert.ok(!existsSync(join(output, command === process.execPath ? 'old' : 'new')), name);
    }
  }
});
