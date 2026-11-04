import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { connect } from 'node:net';
import { existsSync } from 'node:fs';

// 必须在 import server 之前设定数据目录，避免落到真实 home
const DATA_DIR = mkdtempSync(join(tmpdir(), 'tl-server-'));
process.env.TOKEN_LENS_DATA_DIR = DATA_DIR;

const { startServer } = await import('../../src/core/server.js');

const DIST_INDEX = join(process.cwd(), 'dashboard', 'dist', 'index.html');

/**
 * 用原始 socket 发请求，用于伪造 Host（node:http 客户端会覆盖该头）。
 *
 * @param {number} port
 * @param {string} requestLine
 * @returns {Promise<string>} 首行状态
 */
function rawRequest(port, requestLine) {
  return new Promise((resolve, reject) => {
    const socket = connect(port, '127.0.0.1', () => {
      socket.write(requestLine);
    });
    let buffer = '';
    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      if (buffer.includes('\r\n')) {
        socket.destroy();
        resolve(buffer.split('\r\n')[0]);
      }
    });
    socket.on('error', reject);
    socket.setTimeout(3000, () => { socket.destroy(); reject(new Error('timeout')); });
  });
}

test('服务：/api/v1 需要令牌，旧入口已下线，静态页注入令牌', async (t) => {
  const { server, port, token } = await startServer(19101);
  const auth = { Authorization: `Bearer ${token}` };
  try {
    const summary = await (await fetch(`http://127.0.0.1:${port}/api/v1/usage/summary`, { headers: auth })).json();
    assert.equal(typeof summary.totals.gross_tokens, 'number');
    assert.equal(typeof summary.totals.cost_usd === 'string' || summary.totals.cost_usd === null, true);

    const series = await (await fetch(`http://127.0.0.1:${port}/api/v1/usage/timeseries?granularity=day`, { headers: auth })).json();
    assert.ok(Array.isArray(series.points));

    const breakdown = await (await fetch(`http://127.0.0.1:${port}/api/v1/usage/breakdown?by=model`, { headers: auth })).json();
    assert.ok(Array.isArray(breakdown.groups));

    const pricing = await (await fetch(`http://127.0.0.1:${port}/api/v1/pricing`, { headers: auth })).json();
    assert.ok(Array.isArray(pricing.models));

    // 无令牌必须 401，不能靠路径前缀绕过
    const noAuth = await fetch(`http://127.0.0.1:${port}/api/v1/usage/summary`);
    assert.equal(noAuth.status, 401);

    // 旧兼容入口与临时取令牌端点都已删除：带令牌也只能是 404
    for (const dead of ['/functions/token-lens-usage-summary', '/functions/token-lens-local-sync', '/api/local-auth']) {
      const res = await fetch(`http://127.0.0.1:${port}${dead}`, { headers: auth });
      assert.equal(res.status, 404, dead + ' 必须返回 404');
    }

    if (existsSync(DIST_INDEX)) {
      const res = await fetch(`http://127.0.0.1:${port}/`);
      assert.equal(res.status, 200);
      const html = await res.text();
      assert.ok(html.includes('<div id="root">'));
      assert.ok(html.includes(`content="${token}"`), '首页必须注入 API 令牌');
    } else {
      t.diagnostic('dashboard/dist 不存在，静态托管未验证');
    }
  } finally {
    server.close();
  }
});

test('/api/v1 需要 bearer 令牌', async () => {
  const { server, port, token } = await startServer(19102);
  try {
    const anon = await fetch(`http://127.0.0.1:${port}/api/v1/health`);
    assert.equal(anon.status, 401);
    const body = await anon.json();
    assert.equal(body.error.code, 'unauthorized');
    assert.equal(anon.headers.get('access-control-allow-origin'), null, '不得下发 CORS 头');

    const authed = await fetch(`http://127.0.0.1:${port}/api/v1/health`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    assert.equal(authed.status, 200);
    const health = await authed.json();
    assert.equal(health.ok, true);
    assert.equal(health.port, port);
  } finally {
    server.close();
  }
});

test('/api/v1/health 的版本与根 package.json 一致', async (t) => {
  const { server, port, token } = await startServer(0);
  t.after(() => new Promise(resolve => server.close(resolve)));
  const response = await fetch(`http://127.0.0.1:${port}/api/v1/health`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(3000)
  });
  assert.equal(response.status, 200);
  const health = await response.json();
  const packageJson = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'));
  assert.equal(health.version, packageJson.version);
});

test('/api/v1/usage/summary 返回统一口径', async () => {
  const { server, port, token } = await startServer(19103);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/usage/summary`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.ok(body.totals);
    for (const key of ['gross_tokens', 'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']) {
      assert.ok(key in body.totals, `缺少字段 ${key}`);
    }
    assert.ok(!('billable_total_tokens' in body.totals), '不得返回含义重叠的第二个总量');
    assert.ok(body.snapshot.price_version);
  } finally {
    server.close();
  }
});

test('非本机 Host 被拒绝（421）', async () => {
  const { server, port } = await startServer(19104);
  try {
    const statusLine = await rawRequest(
      port,
      'GET /api/v1/health HTTP/1.1\r\nHost: evil.example.com\r\nConnection: close\r\n\r\n'
    );
    assert.match(statusLine, /421/);
  } finally {
    server.close();
  }
});

test('跨源写请求被拒绝（403）', async () => {
  const { server, port, token } = await startServer(19105);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/sync`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, Origin: 'https://evil.example.com' }
    });
    assert.equal(res.status, 403);
    const body = await res.json();
    assert.equal(body.error.code, 'forbidden_origin');
  } finally {
    server.close();
  }
});

test('同源写请求可以执行同步', async () => {
  const { server, port, token } = await startServer(19106);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/sync`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, Origin: `http://127.0.0.1:${port}` }
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(typeof body.attempted, 'number');
  } finally {
    server.close();
  }
});

test('端口被占用时顺延到下一个', async () => {
  const { createServer: createNetServer } = await import('node:net');
  const OCCUPIED = 19107;
  const blocker = createNetServer();
  await new Promise((resolve) => blocker.listen(OCCUPIED, '127.0.0.1', resolve));

  try {
    const { server, port } = await startServer(OCCUPIED);
    try {
      assert.equal(port, OCCUPIED + 1);
    } finally {
      server.close();
    }
  } finally {
    await new Promise((resolve) => blocker.close(resolve));
  }
});

