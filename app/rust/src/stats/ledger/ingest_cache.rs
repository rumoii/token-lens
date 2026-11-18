use super::{Clock, Connection, Ledger, Result, Transaction, TransactionBehavior};
use rusqlite::{params, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, path::Path};

#[derive(Serialize, Deserialize)]
pub(in crate::stats) struct FileOutput {
    pub records: Vec<Value>,
    pub notes: HashMap<String, i64>,
}

pub(in crate::stats) struct CachedFile {
    pub fingerprint: String,
    pub payload: Vec<u8>,
    pub replaces: Vec<String>,
}

pub(super) fn migrate(
    db: &Connection,
    path: &Path,
    clock: &Clock,
    backup_needed: bool,
) -> Result<()> {
    let transaction = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
    let version: i64 = transaction.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version >= 7 {
        return Ok(());
    }
    let on_disk = path != Path::new(":memory:");
    if backup_needed && on_disk {
        let date = clock.iso();
        let backup = (0..)
            .map(|suffix| {
                path.with_file_name(format!(
                    "ledger-v6-{}-{}-{suffix}.db",
                    &date[..10],
                    clock.millis()
                ))
            })
            .find(|backup| !backup.exists())
            .unwrap();
        // Hold the writer lock on the ledger while a second connection snapshots
        // committed data, including the WAL, into the backup.
        let reader = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        reader.execute("VACUUM INTO ?", [backup.to_string_lossy().as_ref()])?;
    }
    transaction.execute_batch(include_str!("ingest_cache.sql"))?;
    transaction.execute_batch("PRAGMA user_version=7;")?;
    transaction.commit()?;
    if on_disk {
        crate::diagnostics::RuntimeLog::new(path.parent().unwrap_or(Path::new(".")), None).write(
            "INFO",
            "ledger",
            "migration schema=6->7",
        );
    }
    Ok(())
}

impl Ledger {
    pub(in crate::stats) fn cache_fingerprints(
        &self,
        source: &str,
    ) -> Result<HashMap<String, String>> {
        let mut stmt = self
            .db
            .prepare_cached("SELECT path,fingerprint FROM ingest_files WHERE source=?")?;
        let entries = stmt.query_map([source], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(entries.collect::<std::result::Result<_, _>>()?)
    }

    pub(in crate::stats) fn cached_file(
        &self,
        source: &str,
        path: &str,
    ) -> Result<Option<FileOutput>> {
        let payload: Option<Vec<u8>> = self
            .db
            .prepare_cached("SELECT payload FROM ingest_files WHERE source=? AND path=?")?
            .query_row(params![source, path], |row| row.get(0))
            .optional()?;
        Ok(payload.and_then(|bytes| serde_json::from_slice(&bytes).ok()))
    }

    pub(in crate::stats) fn cache_needs_replay(&self, source: &str) -> Result<bool> {
        Ok(self
            .db
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM ingest_pending_sources WHERE source=?1)
              OR EXISTS(
                SELECT 1 FROM ingest_file_replaces r
                JOIN usage_records u ON u.record_key=r.target
                WHERE r.source=?1 AND u.active=1
              )",
            )?
            .query_row([source], |row| row.get(0))?)
    }

    pub(in crate::stats) fn cache_begin_source(&self, source: &str, remove: &[&str]) -> Result<()> {
        let transaction = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        transaction
            .prepare_cached("INSERT OR IGNORE INTO ingest_pending_sources(source) VALUES (?)")?
            .execute([source])?;
        for path in remove {
            Self::write_ingest_file(&transaction, source, path, None)?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub(in crate::stats) fn cache_finish_source(&self, source: &str) -> Result<()> {
        self.db
            .prepare_cached("DELETE FROM ingest_pending_sources WHERE source=?")?
            .execute([source])?;
        Ok(())
    }

    pub(in crate::stats) fn write_ingest_file(
        transaction: &Transaction<'_>,
        source: &str,
        path: &str,
        cached: Option<&CachedFile>,
    ) -> Result<()> {
        if let Some(cached) = cached {
            transaction.prepare_cached(
                "INSERT INTO ingest_files(source,path,fingerprint,payload) VALUES (?,?,?,?)
                 ON CONFLICT(source,path) DO UPDATE SET fingerprint=excluded.fingerprint,payload=excluded.payload",
            )?.execute(params![source, path, cached.fingerprint, cached.payload])?;
            transaction
                .prepare_cached("DELETE FROM ingest_file_replaces WHERE source=? AND path=?")?
                .execute(params![source, path])?;
            let mut insert = transaction.prepare_cached(
                "INSERT OR IGNORE INTO ingest_file_replaces(source,path,target) VALUES (?,?,?)",
            )?;
            for target in &cached.replaces {
                insert.execute(params![source, path, target])?;
            }
        } else {
            transaction
                .prepare_cached("DELETE FROM ingest_files WHERE source=? AND path=?")?
                .execute(params![source, path])?;
        }
        Ok(())
    }
}
