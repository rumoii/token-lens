import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { connect } from 'node:net';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';

const REPO = process.cwd();

/**
 * 等待服务与其账本完全关闭，Windows 上文件句柄释放是异步的。
 *
 * @param {import('node:http').Server} server
 * @returns {Promise<void>}
 */
function closeServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

/**
 * 每个用例一个干净数据目录。
 *
 * @returns {string}
 */
function freshDir() {
  return mkdtempSync(join(tmpdir(), 'tl-reg-'));
}

/**
 * 用隔离环境跑一次 CLI。
 *
 * @param {string[]} args
 * @param {string} home
 * @returns {{status:number|null, stdout:string, stderr:string}}
 */
function runCli(args, home) {
  const env = { ...process.env, USERPROFILE: home, HOME: home,
    APPDATA: join(home, 'AppData', 'Roaming'), LOCALAPPDATA: join(home, 'AppData', 'Local') };
  delete env.DB_PATH;
  delete env.TOKEN_LENS_DATA_DIR;

  const r = spawnSync(process.execPath, [join(REPO, 'bin', 'lens.js'), ...args],
    { cwd: REPO, env, encoding: 'utf8' });
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

test('D1 空用户目录下 summary 可用并自动建目录', () => {
  const home = freshDir();
  try {
    const result = runCli(['summary'], home);
    assert.equal(result.status, 0, `stderr: ${result.stderr}`);
    assert.equal(result.stderr.trim(), '', '不得输出错误');
    assert.ok(existsSync(join(home, '.token-lens')), '数据目录必须被创建');
    assert.ok(result.stdout.includes('Token Lens Usage Summary'));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('D2/D3 Summary 与 Daily/Monthly 口径一致，分项不翻倍', async () => {
  const dir = freshDir();
  const previous = process.env.TOKEN_LENS_DATA_DIR;
  process.env.TOKEN_LENS_DATA_DIR = dir;

  const ledger = new Ledger(join(dir, 'ledger.db'));
  ledger.write.ingestBatch([
    { source: 'claude', record_key: 'r1', session_id: 's1', model: 'claude-opus-4-1',
      observed_at: '2026-10-10T02:00:00.000Z', kind: 'event',
      input_tokens: 1_000_000, output_tokens: 500_000,
      cache_read_tokens: 2_000_000, cache_write_tokens: 500_000 },
    { source: 'codex', record_key: 'r2', session_id: 's2', model: 'gpt-6.1-sol',
      observed_at: '2026-10-11T02:00:00.000Z', kind: 'event',
      input_tokens: 100_000, output_tokens: 20_000,
      cache_read_tokens: 0, cache_write_tokens: 0 }
  ], { priceOf: costOf });
  ledger.close();

  const { startServer } = await import('../../src/core/server.js');
  const { server, port, token } = await startServer(19120);

  try {
    const get = async (path) =>
      (await fetch(`http://127.0.0.1:${port}${path}`, {
        headers: { Authorization: `Bearer ${token}` }
      })).json();

    const summary = await get('/api/v1/usage/summary');
    const daily = await get('/api/v1/usage/timeseries?granularity=day');
    const monthly = await get('/api/v1/usage/timeseries?granularity=month');

    const dailySum = daily.points.reduce((s, d) => s + d.gross_tokens, 0);
    const monthlySum = monthly.points.reduce((s, m) => s + m.gross_tokens, 0);
    const expected = 1_000_000 + 500_000 + 2_000_000 + 500_000 + 100_000 + 20_000;

    assert.equal(summary.totals.gross_tokens, expected);
    assert.equal(dailySum, expected, '日视图必须等于总额（含 cache_write）');
    assert.equal(monthlySum, expected, '月视图必须等于总额（含 cache_write）');

    const dailyCost = daily.points.reduce((s, d) => s + Number(d.cost_usd), 0);
    assert.ok(dailyCost > 0, '日视图金额不得恒为 0');
    assert.equal(
      dailyCost.toFixed(4),
      Number(summary.totals.cost_usd).toFixed(4),
      '日视图金额之和必须等于总额'
    );

    const breakdown = await get('/api/v1/usage/breakdown?by=model');
    const claude = breakdown.groups.find((g) => g.key === 'claude-opus-4-1');
    assert.equal(claude.input_tokens, 1_000_000, '分项不得被加两遍');
    assert.equal(claude.cache_read_tokens, 2_000_000);
    assert.equal(claude.cache_write_tokens, 500_000, '缓存写必须真实透出');
    assert.equal(claude.gross_tokens, 4_000_000);

    // 旧兼容入口已删除：带令牌请求也必须 404，而不是回落成页面
    for (const dead of ['/functions/token-lens-usage-summary', '/api/local-auth']) {
      const res = await fetch(`http://127.0.0.1:${port}${dead}`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      assert.equal(res.status, 404, dead + ' 必须已下线');
    }
  } finally {
    await closeServer(server);
    if (previous === undefined) delete process.env.TOKEN_LENS_DATA_DIR;
    else process.env.TOKEN_LENS_DATA_DIR = previous;
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('D7 只监听回环，局域网地址不可达', async (t) => {
  const dir = freshDir();
  const previous = process.env.TOKEN_LENS_DATA_DIR;
  process.env.TOKEN_LENS_DATA_DIR = dir;

  const { startServer } = await import('../../src/core/server.js');
  const { server, port } = await startServer(19121);

  try {
    const addr = server.address();
    assert.equal(addr.address, '127.0.0.1', `监听地址必须是回环，实际为 ${addr.address}`);

    const lanIp = findLanIp();
    if (!lanIp) {
      t.diagnostic('本机没有非回环 IPv4，局域网可达性未验证');
      return;
    }

    const reachable = await new Promise((resolve) => {
      const socket = connect(port, lanIp);
      const done = (value) => { socket.destroy(); resolve(value); };
      socket.once('connect', () => done(true));
      socket.once('error', () => done(false));
      socket.setTimeout(1500, () => done(false));
    });

    assert.equal(reachable, false, `服务不应在 ${lanIp}:${port} 上可达`);
  } finally {
    await closeServer(server);
    if (previous === undefined) delete process.env.TOKEN_LENS_DATA_DIR;
    else process.env.TOKEN_LENS_DATA_DIR = previous;
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

/**
 * @returns {string|null}
 */
function findLanIp() {
  const ifaces = networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name] || []) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address;
    }
  }
  return null;
}



