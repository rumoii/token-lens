
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
