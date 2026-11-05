import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const RUNNER = join(process.cwd(), 'scripts', 'verify-local.mjs');
const ENV_EXEMPTIONS = new Set(['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA']);

function discoveryEnvNames() {
  const adapters = join(process.cwd(), 'src/core/adapters');
  const files = [join(process.cwd(), 'src/core/discovery.js'),
    ...readdirSync(adapters, { recursive: true }).filter(name => name.endsWith('.js')).map(name => join(adapters, name))];
  return [...new Set(files.flatMap(file => [...readFileSync(file, 'utf8').matchAll(/process\.env\.([A-Z_][A-Z_0-9]*)/g)]
    .map(match => match[1])))].sort();
}

function fixture(t, failAt = '') {
  const root = mkdtempSync(join(tmpdir(), 'tl-verify-fixture with spaces-'));
  t.after(() => rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  const files = {
    'probe.cjs': `
      const assert = require('node:assert/strict');
      const fs = require('node:fs');
      const os = require('node:os');
      const path = require('node:path');
      module.exports = (step) => {
        const home = process.env.HOME;
        const sandbox = path.dirname(home);
        assert.equal(os.homedir(), home);
        assert.equal(process.env.USERPROFILE, home);
        assert.equal(process.env.APPDATA, path.join(home, 'AppData', 'Roaming'));
        assert.equal(process.env.LOCALAPPDATA, path.join(home, 'AppData', 'Local'));
        assert.equal(process.env.TOKEN_LENS_DATA_DIR, path.join(sandbox, 'data'));
        assert.equal(os.tmpdir(), path.join(sandbox, 'tmp'));
        assert.ok(fs.existsSync(process.env.TOKEN_LENS_DATA_DIR));
        assert.ok(!Object.keys(process.env).some(key => key.toUpperCase() === 'DB_PATH'));
        assert.notEqual(home, path.join(__dirname, 'caller-home'));
        fs.appendFileSync(path.join(__dirname, 'checks.jsonl'), JSON.stringify({ step, sandbox, cwd: process.cwd(), args: process.argv.slice(2), envKeys: Object.keys(process.env) }) + '\\n');
        fs.writeFileSync(path.join(home, 'probe'), step);
        if (step === ${JSON.stringify(failAt)}) process.exit(23);
      };
    `,
    'test/core/probe.test.js': "require('../../probe.cjs')('core');\n",
    'dashboard/node_modules/vitest/vitest.mjs': "import probe from '../../../probe.cjs'; probe('dashboard');\n",
    'dashboard/node_modules/vite/bin/vite.js': "require('../../../../probe.cjs')('build');\n",
    'dashboard/node_modules/typescript/bin/tsc': "require('../../../../probe.cjs')('types');\n"
  };
  for (const [name, text] of Object.entries(files)) {
    const file = join(root, name);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  }
  mkdirSync(join(root, 'scripts'));
  copyFileSync(RUNNER, join(root, 'scripts', 'verify-local.mjs'));
  return root;
}

function run(root, args = [], overrides = {}) {
  return spawnSync(process.execPath, [join(root, 'scripts', 'verify-local.mjs'), ...args], {
    // The entry point must locate its checkout independently of the caller's cwd.
    cwd: tmpdir(), encoding: 'utf8', timeout: 30_000, windowsHide: true,
    env: {
      ...process.env, HOME: join(root, 'caller-home'), USERPROFILE: join(root, 'caller-home'),
      TOKEN_LENS_DATA_DIR: join(root, 'caller-data'), DB_PATH: join(root, 'caller.db'), ...overrides
    }
  });
}

test('验证入口：子进程看不到调用方的客户端路径覆盖变量', (t) => {
  const names = discoveryEnvNames().filter(name => !ENV_EXEMPTIONS.has(name));
  for (const lowerCase of [false, true]) {
    const root = fixture(t);
    const overrides = Object.fromEntries(names.map(name => [lowerCase ? name.toLowerCase() : name, join(root, 'client-path')]));
    const result = run(root, ['all'], overrides);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const steps = records(root);
    assert.equal(steps.length, 4);
    for (const step of steps) {
      assert.deepEqual(step.envKeys.filter(key => names.includes(key.toUpperCase())), [], step.step);
    }
  }
});

test('验证入口：发现和适配器的环境变量必须在清理名单或明确豁免名单中', (t) => {
  const root = fixture(t);
  const url = pathToFileURL(join(root, 'scripts/verify-local.mjs')).href;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
    const runner = await import(${JSON.stringify(url)});
    console.log(JSON.stringify(runner.CLIENT_ENV_OVERRIDES || []));
  `], { encoding: 'utf8', timeout: 30_000, windowsHide: true });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const cleanup = JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
  const missing = discoveryEnvNames().filter(name => !ENV_EXEMPTIONS.has(name) && !cleanup.includes(name));
  assert.deepEqual(missing, [], '新增发现变量时要同步 CLIENT_ENV_OVERRIDES 或明确列出豁免原因');
  assert.deepEqual(records(root), [], '导入清理名单不能执行验证任务');
});

function records(root) {
  const log = join(root, 'checks.jsonl');
  return existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line)) : [];
}

test('验证入口：运行全部检查，隔离继承的环境并清理临时目录', (t) => {
  const root = fixture(t);
  const result = run(root);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const steps = records(root);
  assert.deepEqual(steps.map((row) => row.step), ['core', 'dashboard', 'build', 'types']);
  assert.equal(steps[0].cwd, root);
  assert.equal(steps[1].cwd, join(root, 'dashboard'));
  assert.deepEqual(steps[1].args, ['run']);
  assert.deepEqual(steps[2].args, ['build']);
  assert.deepEqual(steps[3].args, ['--noEmit']);
  assert.equal(new Set(steps.map((row) => row.sandbox)).size, 1);
  assert.equal(existsSync(steps[0].sandbox), false);
  assert.equal(existsSync(join(root, 'caller-home')), false);
  assert.equal(existsSync(join(root, 'caller-data')), false);
});

for (const [index, step] of ['core', 'dashboard', 'build', 'types'].entries()) {
  test(`验证入口：${step} 失败时返回非零，不执行后续检查并清理`, (t) => {
    const root = fixture(t, step);
    const result = run(root, ['all']);
    assert.notEqual(result.status, 0, result.stderr + result.stdout);
    const steps = records(root);
    assert.deepEqual(steps.map((row) => row.step), ['core', 'dashboard', 'build', 'types'].slice(0, index + 1));
    assert.match(result.stderr, /failed/);
    assert.equal(existsSync(steps[0].sandbox), false);
  });
}

test('验证入口：缺少本地 Vitest 时失败，不运行检查或下载工具', (t) => {
  const root = fixture(t);
  rmSync(join(root, 'dashboard/node_modules/vitest/vitest.mjs'));
  const result = run(root, ['all']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing local file node_modules\/vitest\/vitest.mjs/);
  assert.deepEqual(records(root), []);
});

test('验证入口：core 不依赖仪表盘工具，dashboard 只运行前端测试', (t) => {
  const core = fixture(t);
  rmSync(join(core, 'dashboard/node_modules/vitest/vitest.mjs'));
  const coreResult = run(core, ['core']);
  assert.equal(coreResult.status, 0, coreResult.stderr);
  assert.deepEqual(records(core).map((row) => row.step), ['core']);
  const dashboard = fixture(t);
  const dashboardResult = run(dashboard, ['dashboard']);
  assert.equal(dashboardResult.status, 0, dashboardResult.stderr);
  assert.deepEqual(records(dashboard).map((row) => row.step), ['dashboard']);
});

test('验证入口：未知分组与多余参数必须失败', (t) => {
  const root = fixture(t);
  for (const args of [['unknown'], ['core', 'extra'], ['__proto__']]) {
    const result = run(root, args);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Usage:/);
  }
  assert.deepEqual(records(root), []);
});
