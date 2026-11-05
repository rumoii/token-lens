import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, utimesSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  acquireSyncLock,
  SyncBusyError,
  LegacyLockError,
  isSyncBusyError,
  SYNC_LOCK_DB,
  LEGACY_SYNC_LOCK
} from '../../src/core/sync-lock.js';
import { runIngestion } from '../../src/core/ingest.js';
import { resolveDataDir } from '../../src/core/paths.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { LedgerWriter } from '../../src/core/db/write.js';

test('旧库与采集账本可在同一目录使用不同文件，并协调同一把锁', { timeout: 60_000 }, () => {
  const dir = createTempDir();
  try {
    const legacyPath = join(dir, 'data.db');
    const ledgerPath = join(dir, 'ledger.db');
    const env = { DB_PATH: legacyPath, TOKEN_LENS_DATA_DIR: dir };
    const paths = resolveDataDir({ dataDir: dir, dbPath: ledgerPath, env });
    assert.equal(paths.ledgerPath, ledgerPath);
    assert.equal(paths.dbPath, legacyPath);
    assert.equal(paths.syncLockPath, join(dir, SYNC_LOCK_DB));

    runProbe(`
      const options = { dataDir: dir, dbPath: join(dir, 'ledger.db') };
      writeFileSync(process.env.DB_PATH, 'legacy sentinel');
      const lock = acquireSyncLock(dir);
      try {
        await assert.rejects(runIngestion(options), isSyncBusyError);
        await assert.rejects(runIngestion({ dbPath: options.dbPath }), isSyncBusyError);
        await assert.rejects(runIngestion({ dataDir: dir }), isSyncBusyError);
      } finally { lock.release(); }
      await runIngestion(options);
      assert.equal(readFileSync(process.env.DB_PATH, 'utf8'), 'legacy sentinel');
    `, dir, env);
  } finally { cleanTempDir(dir); }
});

test('路径解析保留旧库用途与默认规则，跨目录配置仍拒绝', { timeout: 60_000 }, (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  const ledgerPath = join(dir, 'custom.db');
  const custom = resolveDataDir({ dbPath: ledgerPath, env: {} });
  assert.equal(custom.ledgerPath, ledgerPath);
  assert.equal(custom.dbPath, join(dir, 'data.db'));
  assert.equal(custom.syncLockPath, join(dir, SYNC_LOCK_DB));
  const defaultPaths = resolveDataDir({ env: {}, home: dir });
  assert.equal(defaultPaths.dataDir, join(dir, '.token-lens'));
  assert.equal(defaultPaths.ledgerPath, join(dir, '.token-lens', 'ledger.db'));
  assert.equal(defaultPaths.dbPath, join(dir, '.token-lens', 'data.db'));
  const legacyPath = join(dir, 'old.db');
  assert.equal(resolveDataDir({ env: { DB_PATH: legacyPath } }).dbPath, legacyPath);
  for (const options of [
    { dataDir: join(dir, 'other'), dbPath: ledgerPath, env: {} },
    { dbPath: ledgerPath, env: { DB_PATH: join(dir, 'other', 'data.db') } },
    { dataDir: dir, env: { DB_PATH: join(dir, 'other', 'data.db') } }
  ]) {
    assert.throws(() => resolveDataDir(options), /数据目录冲突/);
  }
});

function createTempDir(prefix = 'tl-sync-lock-') {
  return mkdtempSync(join(tmpdir(), prefix));
}

function cleanTempDir(dir) {
  assert.equal(realpathSync(dirname(dir)), realpathSync(tmpdir()));
  assert.ok(basename(dir).startsWith('tl-'));
  assert.equal(realpathSync(dir), dir);
  rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}

const WAIT_MS = 10_000;
const COMMAND_MS = 15_000;
const CLI = fileURLToPath(new URL('../../bin/lens.js', import.meta.url));
const coreURL = (file) => JSON.stringify(new URL(`../../src/core/${file}`, import.meta.url).href);

function childEnv(dataDir, overrides = {}) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.toUpperCase() === 'DB_PATH') delete env[key];
  }
  return { ...env, TOKEN_LENS_DATA_DIR: dataDir, ...overrides };
}

function runNode(args, dataDir, overrides = {}, timeout = COMMAND_MS) {
  const result = spawnSync(process.execPath, args, {
    cwd: dataDir, env: childEnv(dataDir, overrides), encoding: 'utf8',
    timeout, killSignal: 'SIGKILL', windowsHide: true
  });
  assert.equal(result.error, undefined,
    `${result.error?.message}; status=${result.status}; signal=${result.signal}\n${result.stdout}\n${result.stderr}`);
  return result;
}

function runProbe(script, dataDir, overrides = {}) {
  const result = runNode(['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { DatabaseSync } from 'node:sqlite';
    import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
    import { join } from 'node:path';
    import { runIngestion } from ${coreURL('ingest.js')};
    import { acquireSyncLock, isSyncBusyError } from ${coreURL('sync-lock.js')};
    import { LedgerWriter } from ${coreURL('db/write.js')};
    import { Ledger } from ${coreURL('db/ledger.js')};
    const dir = process.argv[1];
    ${script}
  `, dataDir], dataDir, overrides);
  assert.equal(result.status, 0, result.stdout + result.stderr);
}

function within(promise, timeout, describe) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(describe())), timeout);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); }
    );
  });
}

const HOLDER_SCRIPT = `
  import { acquireSyncLock } from ${coreURL('sync-lock.js')};
  import { createInterface } from 'node:readline';
  const lock = acquireSyncLock(process.argv[1]);
  process.stdout.write('LOCKED\\n');
  const rl = createInterface({ input: process.stdin });
  rl.once('line', () => { lock.release(); process.exit(0); });
`;

// 每个子进程句柄负责就绪、正常释放和强制回收；目录清理须在这些操作之后。
async function spawnLockHolder(dataDir, { script = HOLDER_SCRIPT, timeout = WAIT_MS, onSpawn = () => {} } = {}) {
  const child = spawn(process.execPath, ['--input-type=module', '-e', script, dataDir], {
    cwd: dataDir, env: childEnv(dataDir), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true
  });
  onSpawn(child);
  let stdout = '';
  let stderr = '';
  let closed = false;
  let processError;
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const describe = (phase) => `${phase}; pid=${child.pid}; code=${child.exitCode}; signal=${child.signalCode}; error=${processError?.message || ''}\nstdout=${stdout}\nstderr=${stderr}`;
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
    if (stdout.split('\n').includes('LOCKED')) readyResolve();
  });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  child.on('error', (error) => { processError = error; readyReject(new Error(describe('子进程启动失败'))); });
  child.stdin.on('error', (error) => { processError = error; });
  const close = new Promise((resolve) => child.once('close', (code, signal) => {
    closed = true;
    readyReject(new Error(describe('子进程在就绪前退出')));
    resolve({ code, signal });
  }));
  const waitForClose = (ms = timeout) => within(close, ms, () => describe('等待子进程退出超时'));
  const stop = async () => {
    if (!closed) child.kill('SIGKILL');
    await waitForClose(WAIT_MS);
  };
  try {
    await within(ready, timeout, () => describe('等待子进程就绪超时'));
  } catch (error) {
    await stop();
    throw error;
  }
  let releaseRequested = false;
  return {
    child,
    stop,
    async release() {
      if (closed) return;
      if (!releaseRequested) {
        releaseRequested = true;
        child.stdin.end('RELEASE\n');
      }
      try {
        const result = await waitForClose();
        assert.equal(result.code, 0, describe('持有锁的子进程退出失败'));
      } catch (error) {
        await stop();
        throw error;
      }
    }
  };
}

test('同一进程内重叠采集被立即拒绝，释放后可重新获取', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  const lock1 = acquireSyncLock(dir);
  assert.ok(lock1);

  // 再次获取应立即抛出 SyncBusyError
  assert.throws(
    () => acquireSyncLock(dir),
    (err) => isSyncBusyError(err) && err instanceof SyncBusyError
  );

  // runIngestion 尝试调用也应抛出 SyncBusyError
  await assert.rejects(
    async () => await runIngestion({ dataDir: dir }),
    (err) => isSyncBusyError(err) && err.code === 'SYNC_BUSY'
  );

  // 释放锁
  lock1.release();

  // 释放后可重新获取
  const lock2 = acquireSyncLock(dir);
  assert.ok(lock2);
  lock2.release();

  // 重复 release 必须安全且幂等
  assert.doesNotThrow(() => lock2.release());
});

test('两个进程访问同一数据目录，第二个被立即拒绝；释放后第二个可重新获取', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  // 进程 1 获取锁并等待确认
  const holder = await spawnLockHolder(dir);

  try {
    // 进程 2（在当前进程中尝试）获取锁，必须被立即拒绝
    assert.throws(
      () => acquireSyncLock(dir),
      (err) => isSyncBusyError(err)
    );

    // 另一个子进程尝试运行采集，也必须失败且退出码非零
    const secondChild = runNode(
      [
        '--input-type=module',
        '-e',
        `
        import { runIngestion } from ${coreURL('ingest.js')};
        await runIngestion({ dataDir: process.argv[1] });
        `,
        dir
      ],
      dir
    );
    assert.notEqual(secondChild.status, 0);
    assert.match(secondChild.stderr, /SYNC_BUSY/);
  } finally {
    // 进程 1 释放锁并退出
    await holder.release();
  }

  // 进程 1 退出后，可以重新获得锁
  const lock = acquireSyncLock(dir);
  assert.ok(lock);
  lock.release();
});

test('不同数据目录互不阻塞', { timeout: 60_000 }, async (t) => {
  const dirA = createTempDir('tl-lock-a-');
  const dirB = createTempDir('tl-lock-b-');
  t.after(() => {
    cleanTempDir(dirA);
    cleanTempDir(dirB);
  });

  const holderA = await spawnLockHolder(dirA);

  try {
    // 目录 A 被锁定，但目录 B 应能自由获取锁
    const lockB = acquireSyncLock(dirB);
    assert.ok(lockB);
    lockB.release();

    const resultB = await runIngestion({ dataDir: dirB });
    assert.equal(typeof resultB.durationMs, 'number');
  } finally {
    await holderA.release();
  }
});

test('持有时间超过旧的 10 分钟阈值仍不能抢锁', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  const holder = await spawnLockHolder(dir);

  try {
    const lockDbFile = join(dir, SYNC_LOCK_DB);
    assert.ok(existsSync(lockDbFile));

    // 将 sync-lock.db 的修改时间与访问时间人为回退至 30 分钟前
    const staleTime = (Date.now() - 30 * 60 * 1000) / 1000;
    utimesSync(lockDbFile, staleTime, staleTime);

    // 新协议依赖 SQLite 事务锁，绝不使用基于时间的过期抢占，依然必须被拒绝
    assert.throws(
      () => acquireSyncLock(dir),
      (err) => isSyncBusyError(err)
    );
  } finally {
    await holder.release();
  }
});

test('正常结束及持有进程被终止后均可重新获取锁', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  // 1. 正常采集结束：锁已自动释放
  const res1 = await runIngestion({ dataDir: dir });
  assert.equal(typeof res1.attempted, 'number');
  const checkLock1 = acquireSyncLock(dir);
  checkLock1.release();

  // 进程终止后，锁文件保留，底层事务锁必须释放。
  const holder = await spawnLockHolder(dir);
  await holder.stop();

  // 确认 sync-lock.db 文件未被删除
  assert.ok(existsSync(join(dir, SYNC_LOCK_DB)));

  // 主进程能够立即重新获取锁
  const recoveredLock = acquireSyncLock(dir);
  assert.ok(recoveredLock);
  recoveredLock.release();
});

test('CLI reprice 遇采集锁时以 1 退出且账本不变，释放锁后可重试', { timeout: 60_000 }, () => {
  const dir = createTempDir();
  let db;
  let lock;
  try {
    db = openLedger(join(dir, 'ledger.db'));
    new LedgerWriter(db).ingestBatch([{
      source: 'codex', record_key: 'reprice-lock', model: 'gpt-6.1-sol', kind: 'event',
      observed_at: '2026-10-10T00:00:00.000Z', input_tokens: 1000, output_tokens: 100,
      cache_read_tokens: 0, cache_write_tokens: 0
    }], { priceOf: () => ({ cost_micros: 7, price_version: 'old', price_source: 'test' }) });
    const snapshot = () => ({
      rows: db.prepare('SELECT * FROM usage_records').all(),
      prices: db.prepare('SELECT * FROM pricing_snapshot').all(),
      runs: db.prepare('SELECT * FROM ingest_runs').all()
    });
    const before = snapshot();
    lock = acquireSyncLock(dir);
    const busy = runNode([CLI, 'reprice', '--data-dir', dir], dir);
    assert.equal(busy.status, 1, busy.stdout + busy.stderr);
    assert.match(busy.stderr, /忙碌|已有同步或采集任务/);
    assert.deepEqual(snapshot(), before, '忙碌时不得改变用量、金额、版本或价格快照');
    lock.release();
    lock = null;

    const retry = runNode([CLI, 'reprice', '--data-dir', dir], dir);
    assert.equal(retry.status, 0, retry.stdout + retry.stderr);
    assert.match(retry.stdout, /重算 1 条记录/);
    const after = snapshot();
    assert.notEqual(after.rows[0].price_version, 'old');
    assert.equal(after.rows[0].input_tokens, before.rows[0].input_tokens);
    assert.equal(after.rows[0].revision, before.rows[0].revision);
    const released = acquireSyncLock(dir);
    released.release();
  } finally {
    lock?.release();
    db?.close();
    cleanTempDir(dir);
  }
});

test('CLI、HTTP 与启动采集均受内核锁保护', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  // 1. CLI collect 遇锁冲突明确报错并以非零退出
  const holder = await spawnLockHolder(dir);

  try {
    const cliResult = runNode([CLI, 'collect', '--data-dir', dir], dir);
    assert.equal(cliResult.status, 1);
    assert.match(cliResult.stderr, /采集冲突/);
  } finally {
    await holder.release();
  }

  // 2. HTTP POST /api/v1/sync 端点保持 409 sync_in_progress 契约
  const previousEnv = process.env.TOKEN_LENS_DATA_DIR;
  process.env.TOKEN_LENS_DATA_DIR = dir;
  let serverRuntime;
  try {
    const { startServer } = await import('../../src/core/server.js');
    serverRuntime = await startServer(19450);
  } finally {
    if (previousEnv === undefined) delete process.env.TOKEN_LENS_DATA_DIR;
    else process.env.TOKEN_LENS_DATA_DIR = previousEnv;
  }

  try {
    // 内核锁定
    const innerLock = acquireSyncLock(dir);

    try {
      const syncRes = await fetch(`http://127.0.0.1:${serverRuntime.port}/api/v1/sync`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${serverRuntime.token}` },
        signal: AbortSignal.timeout(WAIT_MS)
      });
      assert.equal(syncRes.status, 409);
      const syncBody = await syncRes.json();
      assert.equal(syncBody.error.code, 'sync_in_progress');
    } finally { innerLock.release(); }

    // 锁释放后再次发起请求，应当成功返回 200
    const retryRes = await fetch(`http://127.0.0.1:${serverRuntime.port}/api/v1/sync`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${serverRuntime.token}` },
      signal: AbortSignal.timeout(WAIT_MS)
    });
    assert.equal(retryRes.status, 200);
    const retryBody = await retryRes.json();
    assert.equal(typeof retryBody.durationMs, 'number');
  } finally {
    await new Promise((res, rej) => serverRuntime.server.close((err) => (err ? rej(err) : res())));
  }

  // 3. serve 的启动补采在监听之后进行，遇锁跳过且不登记运行：见 desktop.test.js
});

test('检测到遗留 sync.lock 时拒绝采集并明确提示，绝不自动删除', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  const legacyFile = join(dir, LEGACY_SYNC_LOCK);
  const initialContent = JSON.stringify({ pid: 12345, at: Date.now() });
  writeFileSync(legacyFile, initialContent, 'utf8');

  // acquireSyncLock 遇到遗留锁必须抛出 LegacyLockError
  assert.throws(
    () => acquireSyncLock(dir),
    (err) => err instanceof LegacyLockError && err.code === 'LEGACY_SYNC_LOCK' && /新旧采集锁协议不支持混跑/.test(err.message)
  );

  // runIngestion 同样必须抛出 LegacyLockError
  await assert.rejects(
    async () => await runIngestion({ dataDir: dir }),
    (err) => err instanceof LegacyLockError && err.code === 'LEGACY_SYNC_LOCK'
  );

  // 遗留锁文件必须保持原样存在，绝不能被自动删除
  assert.ok(existsSync(legacyFile));
  assert.equal(readFileSync(legacyFile, 'utf8'), initialContent);
});

test('非忙碌错误不会被吞掉或误分类，options.dbPath 统一受协调保护', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));

  // 1. 路径冲突引发的非忙碌错误正常暴露，不伪装成忙碌
  assert.throws(
    () => resolveDataDir({ dataDir: dir, dbPath: join(dir, 'other', 'other.db') }),
    (err) => !isSyncBusyError(err) && /数据目录冲突/.test(err.message)
  );

  // 2. options.dbPath 统一解析出同一数据目录与 syncLockPath
  const customDb = join(dir, 'custom-ledger.db');
  const paths = resolveDataDir({ dbPath: customDb });
  assert.equal(paths.dataDir, dir);
  assert.equal(paths.syncLockPath, join(dir, SYNC_LOCK_DB));

  // 先锁住该目录
  const lock = acquireSyncLock(dir);

  // 传入 options.dbPath 调用 runIngestion，必须能识别冲突，绝不因传参形式绕过协调
  await assert.rejects(
    async () => await runIngestion({ dbPath: customDb }),
    (err) => isSyncBusyError(err)
  );

  lock.release();
});

test('账本初始化失败发生在获锁后，失败后连接和锁均释放', { timeout: 60_000 }, (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  runProbe(`
    const file = join(dir, 'ledger.db');
    const future = new DatabaseSync(file);
    future.exec('PRAGMA user_version = 6');
    future.close();
    const original = DatabaseSync.prototype.prepare;
    let checked = false;
    DatabaseSync.prototype.prepare = function(sql) {
      if (sql === 'PRAGMA user_version') {
        checked = true;
        assert.throws(() => acquireSyncLock(dir), isSyncBusyError);
      }
      return original.call(this, sql);
    };
    try { await assert.rejects(runIngestion({ dataDir: dir }), /高于/); }
    finally { DatabaseSync.prototype.prepare = original; }
    assert.equal(checked, true);
    acquireSyncLock(dir).release();
    const retry = new DatabaseSync(file);
    try {
      retry.exec('PRAGMA busy_timeout = 0; PRAGMA journal_mode = DELETE; PRAGMA user_version = 0');
    } finally { retry.close(); }
    await runIngestion({ dataDir: dir });
  `, dir);
});

for (const phase of ['reprice', 'recordRun']) {
  test(`${phase} 持锁期间抛错，拒绝后连接关闭且下一次采集成功`, { timeout: 60_000 }, (t) => {
    const dir = createTempDir();
    t.after(() => cleanTempDir(dir));
    runProbe(`
      const phase = ${JSON.stringify(phase)};
      const original = LedgerWriter.prototype[phase];
      let writer;
      const failure = new Error('injected-' + phase);
      LedgerWriter.prototype[phase] = function() {
        writer = this;
        assert.throws(() => acquireSyncLock(dir), isSyncBusyError);
        throw failure;
      };
      try { await assert.rejects(runIngestion({ dataDir: dir }), error => error === failure); }
      finally { LedgerWriter.prototype[phase] = original; }
      assert.ok(writer);
      assert.throws(() => original.call(writer, () => null, 'test'), error => {
        assert.equal(error.code, 'ERR_INVALID_STATE');
        assert.match(error.message, phase === 'recordRun' ? /statement has been finalized/ : /database is not open/);
        return true;
      });
      acquireSyncLock(dir).release();
      const retry = await runIngestion({ dataDir: dir });
      assert.equal(typeof retry.durationMs, 'number');
      const ledger = new Ledger(join(dir, 'ledger.db'));
      ledger.close();
    `, dir);
  });
}

test('真实定时回调跳过忙碌、报告普通错误，并在释放后恢复采集', { timeout: 60_000 }, (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  runProbe(`
    import { startServer } from ${coreURL('server.js')};
    const originalInterval = globalThis.setInterval;
    let tick;
    globalThis.setInterval = (callback, delay, ...args) => {
      if (delay === 5 * 60 * 1000) {
        assert.equal(tick, undefined);
        tick = callback;
      }
      return originalInterval(callback, delay, ...args);
    };
    let runtime;
    try { runtime = await startServer(0); }
    finally { globalThis.setInterval = originalInterval; }
    const originalError = console.error;
    const errors = [];
    console.error = (...args) => errors.push(args.join(' '));
    const countRuns = () => {
      const db = new DatabaseSync(join(dir, 'ledger.db'));
      try { return db.prepare('SELECT count(*) AS n FROM ingest_runs').get().n; }
      finally { db.close(); }
    };
    const lastStatus = () => {
      const db = new DatabaseSync(join(dir, 'ledger.db'));
      try { return db.prepare('SELECT status FROM ingest_runs ORDER BY id DESC LIMIT 1').get().status; }
      finally { db.close(); }
    };
    try {
      assert.equal(typeof tick, 'function');
      const before = countRuns();
      const lock = acquireSyncLock(dir);
      try {
        await tick();
        assert.equal(countRuns(), before);
        assert.deepEqual(errors, []);
      } finally { lock.release(); }

      const originalRun = LedgerWriter.prototype.recordRun;
      let failed = false;
      LedgerWriter.prototype.recordRun = function() {
        failed = true;
        assert.throws(() => acquireSyncLock(dir), isSyncBusyError);
        throw new Error('scheduled-write-failed');
      };
      try { await tick(); }
      finally { LedgerWriter.prototype.recordRun = originalRun; }
      assert.equal(failed, true);
      // 运行开始时已登记为 running，收尾失败后标成 failed，界面不会一直显示「正在同步」
      assert.equal(countRuns(), before + 1);
      assert.equal(lastStatus(), 'failed');
      assert.equal(errors.length, 1);
      assert.match(errors[0], /自动同步.*失败.*scheduled-write-failed/);

      await tick();
      assert.equal(countRuns(), before + 2);
      assert.equal(lastStatus(), 'ok');
      assert.equal(errors.length, 1);
      acquireSyncLock(dir).release();
    } finally {
      console.error = originalError;
      await new Promise((resolve, reject) => runtime.server.close(error => error ? reject(error) : resolve()));
    }
  `, dir);
});

test('损坏的协调数据库保持原样并暴露非忙碌错误', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  const path = join(dir, SYNC_LOCK_DB);
  writeFileSync(path, 'not a SQLite database');
  await assert.rejects(runIngestion({ dataDir: dir }), (error) => {
    assert.equal(isSyncBusyError(error), false);
    assert.match(error.message, /not a database/);
    return true;
  });
  assert.equal(readFileSync(path, 'utf8'), 'not a SQLite database');
  assert.equal(existsSync(join(dir, 'ledger.db')), false);
});

test('子进程不发送就绪信号时超时失败，强制回收后可重新获锁', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  let child;
  await assert.rejects(spawnLockHolder(dir, {
    timeout: 1000,
    onSpawn: (process) => { child = process; },
    script: `
      import { acquireSyncLock } from ${coreURL('sync-lock.js')};
      const lock = acquireSyncLock(process.argv[1]);
      process.stderr.write('HOLDING\\n');
      process.stdin.resume();
    `
  }), (error) => /就绪超时/.test(error.message) && /HOLDING/.test(error.message));
  assert.ok(child.exitCode !== null || child.signalCode !== null);
  acquireSyncLock(dir).release();
});

test('子进程不响应释放请求时超时失败，强制回收与重复清理安全', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  const holder = await spawnLockHolder(dir, {
    timeout: 1000,
    script: `
      import { acquireSyncLock } from ${coreURL('sync-lock.js')};
      const lock = acquireSyncLock(process.argv[1]);
      process.stdin.on('data', () => {});
      setInterval(() => {}, 60_000);
      process.stdout.write('LOCKED\\n');
    `
  });
  try {
    await assert.rejects(holder.release(), /退出超时.*pid=/);
    assert.ok(holder.child.exitCode !== null || holder.child.signalCode !== null);
    await holder.release();
    acquireSyncLock(dir).release();
  } finally { await holder.stop(); }
});

test('子进程就绪前失败保留诊断，并回收部分启动的进程', { timeout: 60_000 }, async (t) => {
  const dir = createTempDir();
  t.after(() => cleanTempDir(dir));
  let child;
  await assert.rejects(spawnLockHolder(dir, {
    onSpawn: (process) => { child = process; },
    script: `throw new Error('startup-fixture-failed');`
  }), /startup-fixture-failed/);
  assert.ok(child.exitCode !== null || child.signalCode !== null);
});
