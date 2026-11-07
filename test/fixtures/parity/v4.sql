
    CREATE TABLE usage_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      record_key TEXT NOT NULL UNIQUE,
      content_hash TEXT NOT NULL,
      source TEXT NOT NULL,
      session_id TEXT,
      project_key TEXT,
      model TEXT,
      observed_at TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('event','cumulative')),
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      active INTEGER NOT NULL DEFAULT 1,
      revision INTEGER NOT NULL DEFAULT 1,
      superseded_by INTEGER REFERENCES usage_records(id),
      price_version TEXT,
      cost_micros INTEGER,
      price_source TEXT,
      ingested_at INTEGER NOT NULL DEFAULT (unixepoch())
    );
  ALTER TABLE usage_records ADD COLUMN cache_write_5m_tokens INTEGER;
ALTER TABLE usage_records ADD COLUMN cache_write_1h_tokens INTEGER;
ALTER TABLE usage_records ADD COLUMN ended_at TEXT;
ALTER TABLE usage_records ADD COLUMN source_file TEXT;
ALTER TABLE usage_records ADD COLUMN parser_rev INTEGER;
INSERT INTO usage_records(record_key,content_hash,source,observed_at,kind,input_tokens,output_tokens,cost_micros) VALUES ('old','old-hash','claude','2026-01-15T00:00:00.000Z','event',2,3,19);
PRAGMA user_version=4;
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
INSERT INTO ingest_runs(started_at,finished_at,status,attempted,inserted,notes) VALUES (1768478400,1768478400,'ok',1,1,'[]');
INSERT INTO legacy_records(origin_row_id,content_hash,source,model,timestamp,input_tokens,estimated_cost) VALUES (1,'old','claude','old-model','2025-01-01T00:00:00Z',19,1.25);
INSERT INTO pricing_snapshot(version,catalog_json,verified_at) VALUES ('old','{"version":"old"}','2025-01-01');
