/**
 * 适配器取数：字段不存在就是未知（null），不是 0。
 *
 * 解析中遇到的问题记进 notes：ingest 给每个文件建一份，传给适配器的第二个参数，
 * 文件解析成功后并入 `ingest_runs.counts`。notes 可以不传，单独调用适配器时只是不计数。
 */

/**
 * @typedef {{ bad_lines: number, bad_fields: number, bad_times: number, zero_usage: number }} ParseNotes
 *   bad_lines：解析不了的行或附属数据；bad_fields：存在但不是非负整数的 token 字段；
 *   bad_times：时间缺失或非法、整条不入账的记录；zero_usage：四类都为 0 或未知、不入账的记录。
 */

/** @returns {ParseNotes} */
export function newNotes() {
  return { bad_lines: 0, bad_fields: 0, bad_times: 0, zero_usage: 0 };
}

/**
 * @param {ParseNotes|undefined} notes
 * @param {keyof ParseNotes} kind
 */
export function note(notes, kind) {
  if (notes) notes[kind] = (notes[kind] || 0) + 1;
}

/**
 * 把一个 token 值转成非负整数。不存在 → null；存在但不是非负整数或纯数字字符串 → 记 bad_fields，返回 null。
 *
 * @param {unknown} value
 * @param {ParseNotes} [notes]
 * @returns {number|null}
 */
export function toToken(value, notes) {
  if (value === undefined || value === null) return null;
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0) return value;
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) return Number(value.trim());
  note(notes, 'bad_fields');
  return null;
}

/**
 * 依次找 keys 里第一个存在（不是 undefined 或 null）的字段，按 toToken 转换。与 `??` 链同义：
 * 存在的 0 就是 0，不会落到下一个字段。
 *
 * @param {any} obj
 * @param {string[]} keys
 * @param {ParseNotes} [notes]
 * @returns {number|null}
 */
export function tokenOf(obj, keys, notes) {
  if (!obj || typeof obj !== 'object') return null;
  for (const key of keys) {
    const value = obj[key];
    if (value !== undefined && value !== null) return toToken(value, notes);
  }
  return null;
}

/**
 * 从含缓存的总数里扣掉缓存段。总数未知时结果未知；缓存未知时按没有缓存处理。
 *
 * @param {number|null} total
 * @param {number|null} part
 * @returns {number|null}
 */
export function minus(total, part) {
  if (total === null) return null;
  return Math.max(0, total - (part ?? 0));
}

/**
 * 两段相加（例如输出加思考 token）。两段都未知时未知，一段未知时取另一段。
 *
 * @param {number|null} a
 * @param {number|null} b
 * @returns {number|null}
 */
export function plus(a, b) {
  if (a === null && b === null) return null;
  return (a ?? 0) + (b ?? 0);
}

/**
 * 四类都为 0 或未知：零用量，不入账（调用方记 zero_usage）。
 *
 * @param {...(number|null|undefined)} values
 * @returns {boolean}
 */
export function isEmptyUsage(...values) {
  return values.every((v) => v === null || v === undefined || v === 0);
}
