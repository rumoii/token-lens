CREATE TABLE ingest_files (
  source      TEXT NOT NULL,
  path        TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  payload     BLOB NOT NULL,
  PRIMARY KEY (source, path)
) WITHOUT ROWID;

CREATE TABLE ingest_file_replaces (
  source    TEXT NOT NULL,
  path      TEXT NOT NULL,
  target    TEXT NOT NULL,
  PRIMARY KEY (source, path, target),
  FOREIGN KEY (source, path) REFERENCES ingest_files(source, path) ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE ingest_pending_sources (
  source TEXT PRIMARY KEY
) WITHOUT ROWID;

CREATE TABLE ingest_run_files (
  run_id        INTEGER PRIMARY KEY REFERENCES ingest_runs(id) ON DELETE CASCADE,
  parsed_files  INTEGER NOT NULL,
  cached_files  INTEGER NOT NULL,
  skipped_files INTEGER NOT NULL
);
