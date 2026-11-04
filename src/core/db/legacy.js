import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';

/**
 * 旧库（`unified_records`）只读导入。
 *
 * 旧库可能正被另一个已安装的进程持续写入，因此：
 * - 以 readOnly 打开，绝不建表、不 checkpoint、不迁移；
 * - 只做一次性快照导入，不与新账本混算；
 * - 导入结果进 `legacy_records`，供对照与导出，不参与统计口径。
 *
 * @param {Object} options
 * @param {import('./ledger.js').Ledger} options.ledger 目标账本
 * @param {string} options.sourceDbPath 旧库路径
 * @param {boolean} [options.replace] 先清空 legacy_records
 * @returns {{ available: boolean, imported: number, reason?: string }}
 */
export function importLegacy({ ledger, sourceDbPath, replace = false }) {
  if (!existsSync(sourceDbPath)) {
    return { available: false, imported: 0, reason: '旧库不存在' };
  }

  let db;
  try {
    db = new DatabaseSync(sourceDbPath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 5000');
    db.exec('PRAGMA query_only = ON');
  } catch (err) {
    return { available: false, imported: 0, reason: `旧库无法只读打开：${err.message}` };
  }

  try {
    const hasTable = db.prepare(
      `SELECT count(*) AS cnt FROM sqlite_master WHERE type='table' AND name='unified_records'`
    ).get();

    if (!hasTable || Number(hasTable.cnt) === 0) {
      return { available: false, imported: 0, reason: '旧库没有 unified_records 表' };
    }

    const rows = db.prepare(`
      SELECT id, content_hash, source, session_id, model, timestamp,
             input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, estimated_cost
      FROM unified_records
      ORDER BY id ASC
    `).all();

    return { available: true, imported: ledger.write.importLegacyRows(rows, { replace }) };
  } finally {
    try { db.close(); } catch { /* 只读连接关闭失败不影响已导入数据 */ }
  }
}
