import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveDataDir } from './paths.js';
import { Ledger } from './db/ledger.js';
import { SCHEMA_VERSION } from './db/open.js';
import { loadOrCreateToken } from './http/token.js';
import { createGate } from './http/gate.js';
import { listenWithRetry } from './http/port.js';
import { serveStatic } from './http/static.js';
import { createRouter } from './api/router.js';
import { runIngestion, isSyncBusyError } from './ingest.js';

const __filename = fileURLToPath(import.meta.url);
const DEFAULT_PORT = parseInt(process.env.PORT || '3456', 10);
const MAX_PORT_ATTEMPTS = 10;
const DIST_DIR = resolve(__filename, '..', '..', '..', 'dashboard', 'dist');
const VERSION = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8')).version;

/**
 * @param {import('node:http').ServerResponse} res
 * @param {Object} body
 * @param {number} [status]
 */
function sendJson(res, body, status = 200) {
  if (res.writableEnded) return;
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
}

/**
 * @param {import('node:http').IncomingMessage} _req
 * @param {import('node:http').ServerResponse} res
 * @param {Object} body
 * @param {number} status
 */
function json(_req, res, body, status = 200) {
  sendJson(res, body, status);
}

/**
 * @param {import('node:http').IncomingMessage} _req
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {string} code
 * @param {string} message
 */
function reject(_req, res, status, code, message) {
  sendJson(res, { error: { code, message } }, status);
}

function getLocalIp() {
  const ifaces = networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name] || []) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address;
    }
  }
  return null;
}

/**
 * 启动本地服务。
 *
 * 只监听 127.0.0.1；`/api/*` 需要 bearer 令牌；端口被占时顺延，不静默改口。
 *
 * @param {number} [preferredPort]
 * @param {{ strictPort?: boolean }} [options]
 * @returns {Promise<{ server: import('node:http').Server, port: number, token: string, ledger: Ledger }>}
 */
export async function startServer(preferredPort = DEFAULT_PORT, { strictPort = false } = {}) {
  const paths = resolveDataDir();
  const token = loadOrCreateToken(paths.dataDir);
  const ledger = new Ledger(paths.ledgerPath);

  /** @type {Object} 在 listen 成功后填充 */
  const ctx = {
    queries: ledger.read,
    json,
    reject,
    runSync: null,
    meta: {
      version: VERSION,
      port: 0,
      dataDir: paths.dataDir,
      ledgerPath: paths.ledgerPath,
      schemaVersion: SCHEMA_VERSION
    }
  };

  let ready = false;

  ctx.runSync = async () => {
    return await runIngestion({ dataDir: paths.dataDir });
  };

  const server = createServer(async (req, res) => {
    if (!ready) {
      reject(req, res, 503, 'starting', '服务尚未就绪');
      return;
    }

    const pathname = new URL(req.url || '/', 'http://127.0.0.1').pathname;

    if ((req.method || 'GET').toUpperCase() === 'OPTIONS') {
      // 不下发任何 CORS 头；预检不应出现在同源场景
      res.writeHead(204);
      res.end();
      return;
    }

    try {
      if (!ctx.gate(req, res, pathname)) return;
      const handled = await ctx.router(req, res, pathname);
      if (handled) return;

      // 接口前缀不再回落到 SPA：不存在的 API 必须报 404，而不是回一页 HTML。
      // `/functions/*` 是已删除的旧入口，保留同样的答案，避免调用方把页面当成数据。
      if (pathname.startsWith('/api/') || pathname.startsWith('/functions/')) {
        reject(req, res, 404, 'not_found', `没有这个接口：${pathname}`);
        return;
      }

      await serveStatic({ res, pathname, distDir: DIST_DIR, token, json });
    } catch (err) {
      console.error('[Token Lens] 请求处理失败', err);
      reject(req, res, 500, 'internal', '内部错误');
    }
  });

  let listening;
  try {
    listening = await listenWithRetry(server, preferredPort, strictPort ? 1 : MAX_PORT_ATTEMPTS);
  } catch (err) {
    ledger.close();
    throw err;
  }
  const { port, skipped } = listening;

  ctx.meta.port = port;
  ctx.gate = createGate({ token, port, reject });
  ctx.router = createRouter(ctx);
  ready = true;

  printBanner(port, skipped, paths.dataDir, paths.ledgerPath);

  const syncInterval = setInterval(async () => {
    try {
      const result = await ctx.runSync();
      if (result && result.inserted > 0) {
        console.log(`[自动同步] 新增 ${result.inserted} 条（${(result.durationMs / 1000).toFixed(2)}s）`);
      }
    } catch (err) {
      if (isSyncBusyError(err)) {
        return;
      }
      console.error('[自动同步] 失败', err.message);
    }
  }, 5 * 60 * 1000);
  syncInterval.unref();

  server.once('close', () => {
    clearInterval(syncInterval);
    try { ledger.close(); } catch { /* 已关闭 */ }
  });

  return { server, port, token, ledger };
}

/**
 * @param {number} port
 * @param {number[]} skipped
 * @param {string} dataDir
 * @param {string} ledgerPath
 */
function printBanner(port, skipped, dataDir, ledgerPath) {
  const ip = getLocalIp();
  console.log('\n┌────────────────────────────────────────────────────────┐');
  if (skipped.length > 0) {
    console.log(`│  ⚠️  端口 ${skipped.join(', ')} 已被占用`);
    console.log(`│  ✔  已顺延至 ${port}`);
  } else {
    console.log('│  ✔  Token Lens 服务启动成功');
  }
  console.log('│');
  console.log(`│  ➜ 仅本机可访问: http://127.0.0.1:${port}/`);
  if (ip) console.log(`│  ➜ 局域网地址 ${ip} 不提供访问（只绑定回环）`);
  console.log(`│  ➜ 数据目录: ${dataDir}`);
  console.log(`│  ➜ 账本: ${ledgerPath}`);
  console.log('└────────────────────────────────────────────────────────┘\n');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  startServer(DEFAULT_PORT).catch((err) => {
    console.error('服务启动失败:', err.message);
    process.exit(1);
  });
}
