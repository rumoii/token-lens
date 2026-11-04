import { createHash } from 'node:crypto';

/**
 * 计算记录的确定性内容哈希（SHA-256 前 32 位 hex）。
 * 使用 ASCII Unit Separator (\x1f) 作为字段分隔符，消除 JSON key 顺序不确定性。
 *
 * @param {Object} r
 * @param {string} r.source
 * @param {string} [r.session_id]
 * @param {string} r.timestamp
 * @param {string} [r.model]
 * @param {number} [r.input_tokens]
 * @param {number} [r.output_tokens]
 * @param {number} [r.cache_read_tokens]
 * @param {number} [r.cache_creation_tokens]
 * @returns {string} 32 位 SHA-256 十六进制哈希
 */
export function computeContentHash(r) {
  const canonical = [
    r.source || 'unknown',
    r.session_id || '',
    r.timestamp || '',
    r.model || 'unknown',
    Number(r.input_tokens || 0),
    Number(r.output_tokens || 0),
    Number(r.cache_read_tokens || 0),
    Number(r.cache_creation_tokens || 0)
  ].join('\x1f');

  return createHash('sha256').update(canonical).digest('hex').slice(0, 32);
}
