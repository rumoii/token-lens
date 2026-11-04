import { randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { ensureDataDir } from '../paths.js';

const TOKEN_FILE = 'api-token';

/**
 * 读取（必要时生成）本机 API 令牌。
 *
 * 令牌只落在数据目录内，文件权限在 POSIX 上收到 0600；Windows 上依赖用户目录 ACL。
 *
 * @param {string} dataDir
 * @returns {string}
 */
export function loadOrCreateToken(dataDir) {
  ensureDataDir(dataDir);
  const path = join(dataDir, TOKEN_FILE);

  if (existsSync(path)) {
    const existing = readFileSync(path, 'utf8').trim();
    if (existing.length >= 32) return existing;
  }

  const token = randomBytes(32).toString('hex');
  writeFileSync(path, `${token}\n`, { encoding: 'utf8', mode: 0o600 });
  try {
    chmodSync(path, 0o600);
  } catch {
    // Windows 上 chmod 语义有限，失败不阻断启动
  }
  return token;
}

/**
 * 定长比较，避免按字节提前返回。
 *
 * @param {string} expected
 * @param {string} provided
 * @returns {boolean}
 */
export function tokenMatches(expected, provided) {
  if (typeof provided !== 'string' || typeof expected !== 'string') return false;
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(provided, 'utf8');
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * 从 Authorization 头取 bearer token。
 *
 * @param {string|undefined} header
 * @returns {string|null}
 */
export function bearerFrom(header) {
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1] : null;
}
