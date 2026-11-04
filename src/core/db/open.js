import { DatabaseSync } from 'node:sqlite';
import { dirname } from 'node:path';
import { ensureDataDir } from '../paths.js';

/**
 * 当前账本结构版本。改结构时递增，并在 migrate 里补一条分支。
 */
export const SCHEMA_VERSION = 5;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS usage_records (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  record_key        TEXT    NOT NULL UNIQUE,
  content_hash      TEXT    NOT NULL,
  source            TEXT    NOT NULL,
  session_id        TEXT,
  project_key       TEXT,
  model             TEXT,
  provider          TEXT,
  observed_at       TEXT    NOT NULL,
  ended_at          TEXT,
  kind              TEXT    NOT NULL CHECK (kind IN ('event','cumulative')),
  input_tokens      INTEGER,
  output_tokens     INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  cache_write_5m_tokens INTEGER,
  cache_write_1h_tokens INTEGER,
  active            INTEGER NOT NULL DEFAULT 1,
  revision          INTEGER NOT NULL DEFAULT 1,
  superseded_by     INTEGER REFERENCES usage_records(id),
  price_version     TEXT,
  cost_micros       INTEGER,
  price_source      TEXT,
  ingested_at       INTEGER NOT NULL DEFAULT (unixepoch()),
  source_file       TEXT,
  parser_rev        INTEGER
);
CREATE INDEX IF NOT EXISTS idx_usage_source   ON usage_records(source);
CREATE INDEX IF NOT EXISTS idx_usage_observed ON usage_records(observed_at);
CREATE INDEX IF NOT EXISTS idx_usage_session  ON usage_records(source, session_id);
CREATE INDEX IF NOT EXISTS idx_usage_model    ON usage_records(model);
CREATE INDEX IF NOT EXISTS idx_usage_active   ON usage_records(active);

CREATE TABLE IF NOT EXISTS ingest_runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at  INTEGER NOT NULL,
  finished_at INTEGER,
  status      TEXT    NOT NULL,
  attempted   INTEGER NOT NULL DEFAULT 0,
  inserted    INTEGER NOT NULL DEFAULT 0,
  updated     INTEGER NOT NULL DEFAULT 0,
  unchanged   INTEGER NOT NULL DEFAULT 0,
  rejected    INTEGER NOT NULL DEFAULT 0,
  notes       TEXT,
  counts      TEXT
);

CREATE TABLE IF NOT EXISTS legacy_records (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  origin_row_id         INTEGER,
  content_hash          TEXT,
  source                TEXT,
  session_id            TEXT,
  model                 TEXT,
  timestamp             TEXT,
  input_tokens          INTEGER,
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  estimated_cost        REAL,
  imported_at           INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS pricing_snapshot (
  version       TEXT PRIMARY KEY,
  catalog_json  TEXT NOT NULL,
  verified_at   TEXT,
  created_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
`;

/**
 * 打开账本数据库并迁移到当前结构版本。
 *
 * 只在这里做落盘动作；模块导入不得调用。
 *
 * @param {string} dbPath
 * @returns {DatabaseSync}
 */
export function openLedger(dbPath) {
  if (dbPath !== ':memory:') {
    ensureDataDir(dirname(dbPath));
  }

  const db = new DatabaseSync(dbPath);
  try {
    db.exec('PRAGMA journal_mode = WAL');
    db.exec('PRAGMA synchronous = NORMAL');
    db.exec('PRAGMA busy_timeout = 5000');
    db.exec('PRAGMA foreign_keys = ON');
    migrate(db);
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

/**
 * 表上是否已有某列。
 *
 * @param {DatabaseSync} db
 * @param {string} table
 * @param {string} column
 * @returns {boolean}
 */
function hasColumn(db, table, column) {
  const rows = db.prepare(`PRAGMA table_info(${table})`).all();
  return rows.some((row) => String(row?.name || '') === column);
}

/**
 * @param {DatabaseSync} db
 */
export function migrate(db) {
  const row = db.prepare('PRAGMA user_version').get();
  const current = Number(row?.user_version || 0);

  if (current === SCHEMA_VERSION) return;
  if (current > SCHEMA_VERSION) {
    throw new Error(
      `账本结构版本 ${current} 高于本程序支持的 ${SCHEMA_VERSION}，拒绝以旧版本写入`
    );
  }

  db.exec('BEGIN');
  try {
    db.exec(SCHEMA);

    // 版本 1 → 2：缓存写拆档。只加列，不重算历史行——旧行的分档留 NULL，
    // 表示「未知」，计价时回落到 5 分钟档。
    if (current < 2) {
      for (const column of ['cache_write_5m_tokens', 'cache_write_1h_tokens']) {
        if (!hasColumn(db, 'usage_records', column)) {
          db.exec(`ALTER TABLE usage_records ADD COLUMN ${column} INTEGER`);
        }
      }
    }

    // 版本 2 → 3：累计快照的最后活动时间。只加列，历史行留 NULL（未知），
    // 下次采集到同一记录时由 ingest 回填。
    if (current < 3 && !hasColumn(db, 'usage_records', 'ended_at')) {
      db.exec('ALTER TABLE usage_records ADD COLUMN ended_at TEXT');
    }

    // 版本 3 → 4：记录出处与解析器版本，供口径修正时停用旧产出；运行记录增加按类计数。
    // 只加列，历史行留 NULL：出处未知的行不会被停用，版本未知按第 1 版处理。
    if (current < 4) {
      for (const [table, column, type] of [
        ['usage_records', 'source_file', 'TEXT'],
        ['usage_records', 'parser_rev', 'INTEGER'],
        ['ingest_runs', 'counts', 'TEXT']
      ]) {
        if (!hasColumn(db, table, column)) {
          db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
        }
      }
    }
    // 版本 4 → 5：日志明确写出的提供方。只加列，不从模型名回填历史行。
    if (current < 5 && !hasColumn(db, 'usage_records', 'provider')) {
      db.exec('ALTER TABLE usage_records ADD COLUMN provider TEXT');
    }
    db.exec('CREATE INDEX IF NOT EXISTS idx_usage_file ON usage_records(source_file, active)');

    db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}
