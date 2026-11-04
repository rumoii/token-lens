import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { ensureDataDir } from './paths.js';

export const SYNC_LOCK_DB = 'sync-lock.db';
export const LEGACY_SYNC_LOCK = 'sync.lock';

/**
 * 采集任务冲突忙碌错误。
 */
export class SyncBusyError extends Error {
  constructor(message = '已有同步或采集任务在执行中') {
    super(message);
    this.name = 'SyncBusyError';
    this.code = 'SYNC_BUSY';
    this.isBusy = true;
  }
}

/**
 * 检测到旧协议遗留锁文件时的明确拒绝错误。
 */
export class LegacyLockError extends Error {
  constructor(path) {
    super(
      `检测到遗留的锁文件：${path}。新旧采集锁协议不支持混跑，升级或回退前必须退出旧版本全部实例。请确认无旧实例运行后手动删除该文件再重试。`
    );
    this.name = 'LegacyLockError';
    this.code = 'LEGACY_SYNC_LOCK';
    this.lockPath = path;
  }
}

/**
 * 判断错误是否为采集互斥忙碌冲突。
 *
 * @param {any} err
 * @returns {boolean}
 */
export function isSyncBusyError(err) {
  return Boolean(err && (err instanceof SyncBusyError || err.code === 'SYNC_BUSY' || err.isBusy === true));
}

/**
 * 获取跨进程采集锁。
 *
 * 在独立 sync-lock.db 数据库上持有 BEGIN IMMEDIATE 写事务。
 * busy_timeout=0，遇到锁冲突立即抛出 SyncBusyError。
 * 进程被终止或崩溃后，由操作系统和 SQLite 释放底层文件锁。
 * 释放与清理时绝不删除 sync-lock.db，支持重复安全调用。
 *
 * @param {string} dataDir
 * @returns {{ release: () => void }}
 */
export function acquireSyncLock(dataDir) {
  ensureDataDir(dataDir);

  const legacyLockPath = join(dataDir, LEGACY_SYNC_LOCK);
  if (existsSync(legacyLockPath)) {
    throw new LegacyLockError(legacyLockPath);
  }

  const lockDbPath = join(dataDir, SYNC_LOCK_DB);
  let db;
  try {
    db = new DatabaseSync(lockDbPath);
  } catch (err) {
    throw err;
  }

  try {
    db.exec('PRAGMA busy_timeout = 0;');
    db.exec('BEGIN IMMEDIATE;');
  } catch (err) {
    try {
      db.close();
    } catch {
      // 忽略关闭失败
    }

    if (isSqliteBusy(err)) {
      throw new SyncBusyError();
    }
    throw err;
  }

  let released = false;
  return {
    release() {
      if (released) return;
      released = true;
      try {
        db.exec('ROLLBACK;');
      } catch {
        // 事务若已被回滚或连接不可用时忽略
      } finally {
        try {
          db.close();
        } catch {
          // 忽略重复关闭
        }
      }
    }
  };
}

/**
 * @param {any} err
 * @returns {boolean}
 */
function isSqliteBusy(err) {
  if (!err) return false;
  if (err.errcode === 5 || err.errcode === 6) return true;
  const msg = String(err.message || '');
  return /database is (locked|busy)/i.test(msg);
}
