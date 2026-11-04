import { readFile, access } from 'node:fs/promises';
import { join, extname } from 'node:path';

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8'
};

/**
 * 把启动期令牌注入 index.html，前端从 `<meta name="lens-api-token">` 读取。
 *
 * 令牌只出现在同源页面里，不落任何公开文件。
 *
 * @param {string} html
 * @param {string} token
 * @returns {string}
 */
export function injectToken(html, token) {
  const tag = `<meta name="lens-api-token" content="${token}">`;
  if (html.includes('name="lens-api-token"')) return html;
  const head = /<head[^>]*>/i.exec(html);
  if (head) {
    const at = head.index + head[0].length;
    return `${html.slice(0, at)}${tag}${html.slice(at)}`;
  }
  return `${tag}${html}`;
}

/**
 * 静态资源托管 + SPA 回退。
 *
 * @param {Object} options
 * @param {import('node:http').ServerResponse} options.res
 * @param {string} options.pathname
 * @param {string} options.distDir
 * @param {string} options.token
 * @param {(res: any, body: any, status?: number) => void} options.json
 * @returns {Promise<void>}
 */
export async function serveStatic({ res, pathname, distDir, token, json }) {
  const cleanPath = decodeURIComponent(pathname).replace(/\.\./g, '');
  const targetPath = cleanPath === '/'
    ? join(distDir, 'index.html')
    : join(distDir, cleanPath);

  if (!targetPath.startsWith(distDir)) {
    json(res, { error: { code: 'not_found', message: '路径越界' } }, 404);
    return;
  }

  try {
    await access(targetPath);
    const data = await readFile(targetPath);
    const ext = extname(targetPath).toLowerCase();

    if (ext === '.html') {
      const html = injectToken(data.toString('utf8'), token);
      const body = Buffer.from(html, 'utf8');
      res.writeHead(200, {
        'Content-Type': MIME_TYPES['.html'],
        'Content-Length': body.length,
        'Cache-Control': 'no-cache'
      });
      res.end(body);
      return;
    }

    res.writeHead(200, {
      'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      'Content-Length': data.length,
      'Cache-Control': 'public, max-age=31536000, immutable'
    });
    res.end(data);
  } catch {
    try {
      const indexHtml = await readFile(join(distDir, 'index.html'), 'utf8');
      const body = Buffer.from(injectToken(indexHtml, token), 'utf8');
      res.writeHead(200, {
        'Content-Type': MIME_TYPES['.html'],
        'Content-Length': body.length,
        'Cache-Control': 'no-cache'
      });
      res.end(body);
    } catch {
      json(res, {
        error: {
          code: 'not_found',
          message: 'Dashboard dist 不存在，先运行 npm run dashboard:build'
        }
      }, 404);
    }
  }
}
