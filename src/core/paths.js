import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { mkdirSync } from 'node:fs';

/**
 * 解析数据目录与数据库文件位置。
 *
 * 优先级（高到低）：
 *   1. options.dataDir / options.dbPath  显式指定
 *   2. env.TOKEN_LENS_DATA_DIR
 *   3. env.DB_PATH                       兼容旧配置：视作数据库文件路径
 *   4. 默认 <home>/.token-lens
 *
 * 同时给出 dataDir 与 dbPath/DB_PATH 且指向不同目录时直接报错，不做猜测。
 *
 * @param {Object} [options]
 * @param {string} [options.dataDir]
 * @param {string} [options.dbPath] 自定义采集账本路径，与返回的旧库 dbPath 区分
 * @param {string} [options.dbFileName] 默认 data.db
 * @param {NodeJS.ProcessEnv} [options.env]
 * @param {string} [options.home]
 * @returns {{ dataDir: string, ledgerPath: string, dbPath: string, syncLockPath: string, source: string }}
 */
export function resolveDataDir(options = {}) {
  const env = options.env || process.env;
  const home = options.home || homedir();
  const dbFileName = options.dbFileName || 'data.db';

  const explicitDir = options.dataDir ? resolve(options.dataDir) : null;
  const explicitDbPath = options.dbPath ? resolve(options.dbPath) : null;
  const envDir = env.TOKEN_LENS_DATA_DIR ? resolve(env.TOKEN_LENS_DATA_DIR) : null;
  const legacyDbPath = env.DB_PATH ? resolve(env.DB_PATH) : null;

  if (explicitDir && explicitDbPath && dirname(explicitDbPath) !== explicitDir) {
    throw new Error(
      `数据目录冲突：--data-dir=${explicitDir} 与 dbPath=${explicitDbPath} 指向不同目录，请只保留一个`
    );
  }
  if (legacyDbPath && explicitDbPath && dirname(legacyDbPath) !== dirname(explicitDbPath)) {
    throw new Error(
      `数据目录冲突：DB_PATH=${legacyDbPath} 与 dbPath=${explicitDbPath} 指向不同目录，请只保留一个`
    );
  }
  if (explicitDir && legacyDbPath && dirname(legacyDbPath) !== explicitDir) {
    throw new Error(
      `数据目录冲突：--data-dir=${explicitDir} 与 DB_PATH=${legacyDbPath} 指向不同目录，请只保留一个`
    );
  }
  if (envDir && legacyDbPath && dirname(legacyDbPath) !== envDir) {
    throw new Error(
      `数据目录冲突：TOKEN_LENS_DATA_DIR=${envDir} 与 DB_PATH=${legacyDbPath} 指向不同目录，请只保留一个`
    );
  }

  if (explicitDbPath) {
    const dir = explicitDir || dirname(explicitDbPath);
    return {
      dataDir: dir,
      ledgerPath: explicitDbPath,
      dbPath: legacyDbPath || join(dir, dbFileName),
      syncLockPath: join(dir, 'sync-lock.db'),
      source: explicitDir ? '--data-dir+dbPath' : 'options.dbPath'
    };
  }
  if (explicitDir) {
    return {
      dataDir: explicitDir,
      ledgerPath: join(explicitDir, 'ledger.db'),
      dbPath: join(explicitDir, dbFileName),
      syncLockPath: join(explicitDir, 'sync-lock.db'),
      source: '--data-dir'
    };
  }
  if (envDir) {
    return {
      dataDir: envDir,
      ledgerPath: join(envDir, 'ledger.db'),
      dbPath: join(envDir, dbFileName),
      syncLockPath: join(envDir, 'sync-lock.db'),
      source: 'TOKEN_LENS_DATA_DIR'
    };
  }
  if (legacyDbPath) {
    const dir = dirname(legacyDbPath);
    return {
      dataDir: dir,
      ledgerPath: join(dir, 'ledger.db'),
      dbPath: legacyDbPath,
      syncLockPath: join(dir, 'sync-lock.db'),
      source: 'DB_PATH'
    };
  }

  const defaultDir = join(home, '.token-lens');
  return {
    dataDir: defaultDir,
    ledgerPath: join(defaultDir, 'ledger.db'),
    dbPath: join(defaultDir, dbFileName),
    syncLockPath: join(defaultDir, 'sync-lock.db'),
    source: 'default'
  };
}

/**
 * 建立数据目录。只在真正需要落盘时调用，导入模块不得调用。
 *
 * @param {string} dataDir
 */
export function ensureDataDir(dataDir) {
  if (!isAbsolute(dataDir)) {
    throw new Error(`数据目录必须是绝对路径：${dataDir}`);
  }
  mkdirSync(dataDir, { recursive: true });
}
