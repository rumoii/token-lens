import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const CLI = fileURLToPath(new URL('../../bin/lens.js', import.meta.url));

function fixture(t) {
  const parent = realpathSync(tmpdir());
  const home = mkdtempSync(join(parent, 'tl-cli-args-'));
  t.after(() => {
    assert.equal(dirname(home), parent);
    assert.ok(basename(home).startsWith('tl-cli-args-'));
    assert.equal(realpathSync(home), home);
    rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  });
  const env = { ...process.env };
  const overrides = { HOME: home, USERPROFILE: home, APPDATA: home, LOCALAPPDATA: home };
  for (const key of Object.keys(env)) {
    if (['TOKEN_LENS_DATA_DIR', 'DB_PATH'].includes(key.toUpperCase()) ||
        Object.hasOwn(overrides, key.toUpperCase())) delete env[key];
  }
  Object.assign(env, overrides);
  return { home, env };
}

function run(args, env) {
  return spawnSync(process.execPath, [CLI, ...args], {
    cwd: env.HOME, env, encoding: 'utf8', timeout: 5000, windowsHide: true
  });
}

const invalid = [
  ['collect', '--data-dir'], ['reprice', '--data-dir='], ['--bogus'], ['serve', '--port', 'abc'],
  ['collect', '--data-dir', '--strict-port'], ['collect', '--data-dir', ''],
  ['serve', '--port'], ['serve', '--port='], ['serve', '--port', '--strict-port'],
  ...['0', '65536', '-1', '1.5', '123abc', '1e3', ' '].map(value => ['serve', `--port=${value}`]),
  ['collect', 'extra'], ['summary', '--bogus'], ['unknown-command'], [''], ['', 'collect']
];

for (const args of [['--help'], ['-h'], ...invalid]) {
  test(`CLI 参数：${JSON.stringify(args)} 在访问数据目录前退出`, (t) => {
    const { home, env } = fixture(t);
    const help = args[0] === '--help' || args[0] === '-h';
    const result = run(args, env);
    assert.equal(existsSync(join(home, '.token-lens')), false, result.stdout + result.stderr);
    assert.equal(result.error, undefined);
    assert.equal(result.status, help ? 0 : 2, result.stderr + result.stdout);
    assert.match(help ? result.stdout : result.stderr, /Usage: lens/);
    if (!help) assert.match(result.stderr, /Argument error:/);
    assert.doesNotMatch(result.stdout, /数据目录|Collection Complete|TOKEN_LENS_READY/);
  });
}

test('CLI 帮助和参数错误优先于数据目录冲突检查', (t) => {
  const { home, env } = fixture(t);
  env.TOKEN_LENS_DATA_DIR = join(home, 'data');
  env.DB_PATH = join(home, 'other', 'ledger.db');
  for (const [args, status] of [[['--help'], 0], [['collect', '--data-dir'], 2], [['--bogus'], 2]]) {
    const result = run(args, env);
    assert.equal(result.status, status, result.stderr + result.stdout);
    assert.doesNotMatch(result.stderr, /数据目录冲突/);
  }
  for (const name of ['.token-lens', 'data', 'other']) assert.equal(existsSync(join(home, name)), false);
});

test('CLI 合法 summary 仍支持空格路径和两种 data-dir 写法', (t) => {
  const { home, env } = fixture(t);
  const data = join(home, 'explicit data');
  for (const args of [['summary', '--data-dir', data, '--port', '1'], [`--data-dir=${data}`, 'summary', '--port=65535']]) {
    const result = run(args, env);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /Token Lens Usage Summary/);
    assert.equal(existsSync(join(data, 'ledger.db')), true);
    assert.equal(existsSync(join(home, '.token-lens')), false);
  }
});
