import { createHash } from 'node:crypto';
import { createInterface } from 'node:readline';
import { note } from './_num.js';

/**
 * 从可读流中逐行流式读取并解析 JSON 对象。
 * 跳过空行；解析不了的行跳过并记 bad_lines。
 *
 * @param {import('node:stream').Readable} readableStream
 * @param {import('./_num.js').ParseNotes} [notes]
 * @yields {Object} 解析成功的 JSON 对象
 */
export async function* jsonLines(readableStream, notes) {
  for await (const [obj] of numberedJsonLines(readableStream, notes)) yield obj;
}

/**
 * 同 jsonLines，另给出该对象所在的物理行号（从 1 起，空行与坏行也计数）。
 * 记录没有自带 id 时，用「文件 + 行号」作身份：只追加的日志里它不随新内容变化。
 *
 * @param {import('node:stream').Readable} readableStream
 * @param {import('./_num.js').ParseNotes} [notes]
 * @yields {[Object, number]}
 */
export async function* numberedJsonLines(readableStream, notes) {
  const rl = createInterface({
    input: readableStream,
    crlfDelay: Infinity
  });

  let lineNo = 0;
  for await (const line of rl) {
    lineNo += 1;
    const trimmed = line.trim();
    if (!trimmed) continue;
    let obj;
    try {
      obj = JSON.parse(trimmed);
    } catch {
      // 一行坏了不影响同一文件的其他行，但要计数
      note(notes, 'bad_lines');
      continue;
    }
    yield [obj, lineNo];
  }
}

/**
 * 文件身份段：路径的 sha256 前 12 位，加 `f` 前缀。与行号拼成 `f<hash>:<line>`。
 *
 * @param {string} filePath
 * @returns {string}
 */
export function fileTag(filePath) {
  return `f${createHash('sha256').update(String(filePath)).digest('hex').slice(0, 12)}`;
}

/**
 * 统一时间戳标准化为 ISO-8601 UTC 字符串。
 * 兼容处理秒级 Unix 戳、毫秒级 Unix 戳和 ISO 字符串。
 * 缺失或非法时返回 null，不用 1970 冒充：没有时间的记录由 ingest 记 bad_times 后丢弃。
 *
 * @param {string|number} raw
 * @returns {string|null} 标准 ISO-8601 UTC 字符串
 */
export function normalizeTimestamp(raw) {
  if (!raw) return null;
  const d = typeof raw === 'number' ? new Date(raw < 1e12 ? raw * 1000 : raw) : new Date(raw);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
