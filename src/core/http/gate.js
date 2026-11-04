import { bearerFrom, tokenMatches } from './token.js';

/**
 * 请求准入闸门。
 *
 * 规则（见 specs/api-v1.md）：
 * - 只接受回环 Host，其余一律 421；
 * - `/api/*` 需要 bearer 令牌；
 * - 非只读方法要求 Origin 缺省或同源，否则 403；
 * - 永不下发 CORS 头。
 *
 * @param {Object} options
 * @param {string} options.token
 * @param {number} options.port
 * @param {(req: any, res: any, status: number, code: string, message: string) => void} options.reject
 * @returns {(req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse, pathname: string) => boolean} 放行返回 true
 */
export function createGate({ token, port, reject }) {
  const allowedHosts = new Set([
    `127.0.0.1:${port}`,
    `localhost:${port}`,
    `[::1]:${port}`
  ]);
  const allowedOrigins = new Set([
    `http://127.0.0.1:${port}`,
    `http://localhost:${port}`,
    `http://[::1]:${port}`
  ]);

  return function gate(req, res, pathname) {
    const host = String(req.headers.host || '').toLowerCase();
    if (host && !allowedHosts.has(host)) {
      reject(req, res, 421, 'bad_host', `Host 不在允许列表：${host}`);
      return false;
    }

    const method = (req.method || 'GET').toUpperCase();
    const isWrite = !['GET', 'HEAD', 'OPTIONS'].includes(method);

    if (isWrite) {
      const origin = req.headers.origin;
      if (origin && !allowedOrigins.has(String(origin).toLowerCase())) {
        reject(req, res, 403, 'forbidden_origin', `跨源写请求被拒：${origin}`);
        return false;
      }
    }

    if (pathname.startsWith('/api/')) {
      const provided = bearerFrom(req.headers.authorization);
      if (!provided || !tokenMatches(token, provided)) {
        reject(req, res, 401, 'unauthorized', '缺少或错误的 bearer 令牌');
        return false;
      }
    }

    return true;
  };
}
