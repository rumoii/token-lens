import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Ledger } from '../../src/core/db/ledger.js';
import { acquireSyncLock } from '../../src/core/sync-lock.js';

function launch(t, args = [], setup = () => {}) {
  const root = mkdtempSync(join(tmpdir(), 'tl-desktop-'));
  const home = join(root, 'home');
  const data = join(root, 'data');
  mkdirSync(home);
  mkdirSync(data);
  setup(data);
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'DB_PATH', 'TOKEN_LENS_DATA_DIR', 'NODE_TEST_CONTEXT'].includes(key.toUpperCase())) delete env[key];
  }
  Object.assign(env, { HOME: home, USERPROFILE: home, APPDATA: join(home, 'roaming'), LOCALAPPDATA: join(home, 'local'), TOKEN_LENS_DATA_DIR: data });
  const child = spawn(process.execPath, [resolve('bin/lens.js'), 'serve', '--port', '19220', ...args], { env, windowsHide: true });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  const exited = once(child, 'exit');
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited; });
  const until = async predicate => {
    const deadline = Date.now() + 8000;
    while (!predicate(output) && child.exitCode === null && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    assert.ok(predicate(output), `子进程未到达预期状态：${output}`);
  };
  return { child, data, exited, until, output: () => output };
}

test('serve：监听成功后输出一次就绪 JSON，字段与真实服务一致', { timeout: 12000 }, async t => {
  const run = launch(t);
  await run.until(text => text.includes('TOKEN_LENS_READY '));
  const lines = () => run.output().split(/\r?\n/).filter(line => line.startsWith('TOKEN_LENS_READY '));
  const ready = JSON.parse(lines()[0].slice('TOKEN_LENS_READY '.length));
  assert.deepEqual(Object.keys(ready).sort(), ['data_dir', 'pid', 'port']);
  assert.equal(ready.pid, run.child.pid);
  assert.equal(ready.data_dir, run.data);
  assert.ok(Number.isInteger(ready.port) && ready.port > 0);
  const token = readFileSync(join(run.data, 'api-token'), 'utf8').trim();
  const response = await fetch(`http://127.0.0.1:${ready.port}/api/v1/health`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000) });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).port, ready.port);
  await fetch(`http://127.0.0.1:${ready.port}/api/missing`, { signal: AbortSignal.timeout(3000) });
  assert.equal(lines().length, 1);
});

test('serve --strict-port：占用时退出且没有就绪行，默认仍顺延', { timeout: 12000 }, async t => {
  const blocker = createServer();
  blocker.listen(0, '127.0.0.1');
  await once(blocker, 'listening');
  t.after(() => new Promise(resolve => blocker.close(resolve)));
  const port = blocker.address().port;
  const strict = launch(t, ['--port', String(port), '--strict-port']);
  await strict.until(text => text.includes('TOKEN_LENS_READY ') || strict.child.exitCode !== null);
  assert.equal(strict.child.exitCode, 1, strict.output());
  assert.doesNotMatch(strict.output(), /TOKEN_LENS_READY /);
  assert.match(strict.output(), new RegExp(`端口 ${port} 已被占用`));

  const fallback = launch(t, ['--port', String(port)]);
  await fallback.until(text => text.includes('TOKEN_LENS_READY '));
  const ready = JSON.parse(fallback.output().split('\n').find(line => line.startsWith('TOKEN_LENS_READY ')).slice(17));
  assert.ok(ready.port > port);
});

test('serve --desktop-logs：stdout/stderr 写入日志并按 5MB × 3 轮转', { timeout: 12000 }, async t => {
  const blocker = createServer();
  blocker.listen(0, '127.0.0.1');
  await once(blocker, 'listening');
  t.after(() => new Promise(resolve => blocker.close(resolve)));
  const run = launch(t, ['--port', String(blocker.address().port), '--strict-port', '--desktop-logs'], data => {
    const logs = join(data, 'logs');
    mkdirSync(logs);
    writeFileSync(join(logs, 'kernel.log'), Buffer.alloc(5 * 1024 * 1024, 120));
    writeFileSync(join(logs, 'kernel.log.1'), 'previous');
    writeFileSync(join(logs, 'kernel.log.2'), 'oldest');
  });
  await run.exited;
  assert.equal(run.child.exitCode, 1, run.output());
  const log = readFileSync(join(run.data, 'logs/kernel.log'), 'utf8');
  assert.match(log, /数据目录/);
  assert.match(log, /Execution error:/);
  assert.equal(statSync(join(run.data, 'logs/kernel.log.1')).size, 5 * 1024 * 1024);
  assert.equal(readFileSync(join(run.data, 'logs/kernel.log.2'), 'utf8'), 'previous');
  assert.ok(Buffer.byteLength(log) <= 5 * 1024 * 1024);
});

test('serve --exit-on-stdin-end：stdin 关闭后内核退出（壳退出即管道关闭）', { timeout: 12000 }, async t => {
  const run = launch(t, ['--exit-on-stdin-end']);
  await run.until(text => text.includes('TOKEN_LENS_READY '));
  run.child.stdin.end();
  const timer = setTimeout(() => run.child.kill(), 3000);
  const [code] = await run.exited;
  clearTimeout(timer);
  assert.equal(code, 0, run.output());
});

test('serve：不加 --exit-on-stdin-end 时关闭 stdin 不影响服务', { timeout: 12000 }, async t => {
  const run = launch(t);
  await run.until(text => text.includes('TOKEN_LENS_READY '));
  run.child.stdin.end();
  await new Promise(resolve => setTimeout(resolve, 500));
  const ready = JSON.parse(run.output().split(/\r?\n/).find(line => line.startsWith('TOKEN_LENS_READY ')).slice(17));
  const token = readFileSync(join(run.data, 'api-token'), 'utf8').trim();
  const health = await fetch(`http://127.0.0.1:${ready.port}/api/v1/health`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000) });
  assert.equal(health.status, 200);
  assert.equal(run.child.exitCode, null);
});

function seedLedger(data) {
  const ledger = new Ledger(join(data, 'ledger.db'));
  ledger.write.ingestBatch([{ source: 'claude', record_key: 'seed', model: 'claude-opus-5-5',
    observed_at: '2026-10-01T00:00:00.000Z', kind: 'event',
    input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0 }],
    { priceOf: () => ({ cost_micros: 0, price_version: 'test', price_source: 'test' }) });
  ledger.close();
}

test('serve：有数据的账本先监听再在后台补采，就绪行早于启动同步完成', { timeout: 12000 }, async t => {
  const run = launch(t, [], seedLedger);
  await run.until(text => text.includes('[启动同步] 完成'));
  const text = run.output();
  assert.ok(text.indexOf('TOKEN_LENS_READY ') >= 0 && text.indexOf('TOKEN_LENS_READY ') < text.indexOf('[启动同步] 完成'), text);
  const ready = JSON.parse(text.split(/\r?\n/).find(line => line.startsWith('TOKEN_LENS_READY ')).slice(17));
  const token = readFileSync(join(run.data, 'api-token'), 'utf8').trim();
  const sources = await fetch(`http://127.0.0.1:${ready.port}/api/v1/sources`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000) });
  assert.equal((await sources.json()).last_run.status, 'ok');
});

test('serve：启动时采集锁被占，跳过补采但仍然就绪并提供服务', { timeout: 12000 }, async t => {
  let lock;
  const run = launch(t, [], data => { seedLedger(data); lock = acquireSyncLock(data); });
  t.after(() => lock.release());
  await run.until(text => text.includes('TOKEN_LENS_READY ') && text.includes('[启动同步]'));
  assert.match(run.output(), /\[启动同步\] 跳过/);
  const ready = JSON.parse(run.output().split(/\r?\n/).find(line => line.startsWith('TOKEN_LENS_READY ')).slice(17));
  const token = readFileSync(join(run.data, 'api-token'), 'utf8').trim();
  const headers = { Authorization: `Bearer ${token}` };
  const health = await fetch(`http://127.0.0.1:${ready.port}/api/v1/health`, { headers, signal: AbortSignal.timeout(3000) });
  assert.equal(health.status, 200);
  // 锁在登记运行之前获取：没有运行记录，说明补采没有绕过锁写账本
  const sources = await fetch(`http://127.0.0.1:${ready.port}/api/v1/sources`, { headers, signal: AbortSignal.timeout(3000) });
  assert.equal((await sources.json()).last_run, null);
  assert.equal(run.child.exitCode, null);
});
