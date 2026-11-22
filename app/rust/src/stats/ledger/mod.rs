use super::{
    clock::Clock,
    jscompat::{number_string, string, truthy},
    pricing::EffectivePrices,
    Error, Result,
};
use rusqlite::{
    params, params_from_iter,
    types::{Value as SqlValue, ValueRef},
    Connection, OpenFlags, Statement, Transaction, TransactionBehavior,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::LazyLock;
mod ingest_cache;
mod read;
pub(in crate::stats) use ingest_cache::{CachedFile, FileOutput};

const TOKENS: [&str; 4] = [
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
];
const FIELDS: [&str; 15] = [
    "kind",
    "session_id",
    "project_key",
    "model",
    "provider",
    "observed_at",
    "ended_at",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "cache_write_5m_tokens",
    "cache_write_1h_tokens",
    "source_file",
    "parser_rev",
];
static UPDATE_USAGE: LazyLock<String> = LazyLock::new(|| {
    let assignments = FIELDS.map(|f| format!("{f}=?")).join(",");
    format!("UPDATE usage_records SET content_hash=?,{assignments},revision=revision+1,price_version=?,cost_micros=?,price_source=? WHERE id=?")
});
static INSERT_USAGE: LazyLock<String> = LazyLock::new(|| {
    let placeholders = ["?"; FIELDS.len() + 6].join(",");
    format!(
        "INSERT INTO usage_records(record_key,content_hash,source,{},price_version,cost_micros,price_source) VALUES ({placeholders})",
        FIELDS.join(",")
    )
});
const DELETE_TIMING: &str = "DELETE FROM usage_timings WHERE record_key=?";

pub struct Ledger {
    pub db: Connection,
    pub clock: Clock,
    pub(crate) prices: EffectivePrices,
    prune_cache: std::cell::RefCell<read::PruneCache>,
    timing_revisions: RefCell<Option<TimingFileRevisions>>,
}

pub(crate) const LEDGER_VERSION: i64 = 7;

#[derive(Debug)]
pub(crate) enum ReadOpenError {
    Missing,
    Version(i64),
    Unavailable(Error),
}

impl std::fmt::Display for ReadOpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Missing => f.write_str("No ledger exists. Open Token Lens or run sync first."),
            Self::Version(version) => write!(
                f,
                "Ledger version {version} is unsupported. Open the matching Token Lens app first."
            ),
            Self::Unavailable(error) => error.fmt(f),
        }
    }
}

pub fn sql_value(value: &Value) -> SqlValue {
    match value {
        Value::String(s) => SqlValue::Text(s.clone()),
        Value::Number(n) => n
            .as_i64()
            .map(SqlValue::Integer)
            .unwrap_or_else(|| SqlValue::Real(n.as_f64().unwrap())),
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        _ => SqlValue::Null,
    }
}

pub fn rows(db: &Connection, sql: &str, args: &[Value]) -> Result<Vec<Value>> {
    let mut statement = db.prepare(sql)?;
    query_rows(&mut statement, args)
}

fn cached_rows(db: &Connection, sql: &str, args: &[Value]) -> Result<Vec<Value>> {
    let mut statement = db.prepare_cached(sql)?;
    query_rows(&mut statement, args)
}

fn query_rows(statement: &mut Statement<'_>, args: &[Value]) -> Result<Vec<Value>> {
    let columns: Vec<_> = statement
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect();
    let args: Vec<_> = args.iter().map(sql_value).collect();
    let output = statement
        .query_map(params_from_iter(args), |row| {
            let mut object = serde_json::Map::new();
            for (index, name) in columns.iter().enumerate() {
                let value = match row.get_ref(index)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                    ValueRef::Blob(_) => {
                        return Err(rusqlite::Error::InvalidColumnType(
                            index,
                            name.clone(),
                            rusqlite::types::Type::Blob,
                        ))
                    }
                };
                object.insert(name.clone(), value);
            }
            Ok(Value::Object(object))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(output)
}

pub fn payload_input(record: &Value) -> String {
    let text = |name: &str, default: &str| {
        if truthy(&record[name]) {
            string(&record[name])
        } else {
            default.into()
        }
    };
    let known = |name: &str| {
        if record[name].is_null() {
            "null".into()
        } else {
            number_string(record[name].as_f64().unwrap_or(0.0))
        }
    };
    let mut fields = vec![text("kind", "event"), text("model", "")];
    fields.extend(TOKENS.map(known));
    fields.extend([
        text("observed_at", ""),
        text("ended_at", ""),
        text("session_id", ""),
        known("cache_write_5m_tokens"),
        known("cache_write_1h_tokens"),
    ]);
    if !record["provider"].is_null() {
        fields.push(string(&record["provider"]));
    }
    fields.join("\x1f")
}
pub fn payload_hash(record: &Value) -> String {
    format!("{:x}", Sha256::digest(payload_input(record).as_bytes()))[..32].into()
}

fn validate(r: &Value) -> Option<String> {
    if !r.is_object() {
        return Some("record 不是对象".into());
    }
    if r["source"].as_str().is_none_or(str::is_empty) {
        return Some("缺少 source".into());
    }
    if r["record_key"].as_str().is_none_or(str::is_empty) {
        return Some("缺少 record_key（无稳定身份不得入库）".into());
    }
    if r["observed_at"].as_str().is_none_or(str::is_empty) {
        return Some("缺少 observed_at".into());
    }
    if !r["provider"].is_null() && !r["provider"].is_string() {
        return Some("provider 不是字符串".into());
    }
    if !r["ended_at"].is_null() && !r["ended_at"].is_string() {
        return Some(format!("ended_at 不是时间字符串：{}", r["ended_at"]));
    }
    let kind = r["kind"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("event");
    if !matches!(kind, "event" | "cumulative") {
        return Some(format!("kind 非法：{kind}"));
    }
    for field in TOKENS {
        if !r[field].is_null()
            && !r[field]
                .as_f64()
                .is_some_and(|n| n >= 0.0 && n.fract() == 0.0)
        {
            return Some(format!("{field} 不是非负整数：{}", r[field]));
        }
    }
    None
}

fn increment(stats: &mut Value, field: &str) {
    stats[field] = json!(stats[field].as_i64().unwrap_or(0) + 1);
}
fn anomaly(stats: &mut Value, value: String) {
    stats["anomalies"]
        .as_array_mut()
        .unwrap()
        .push(json!(value));
}
fn gross(record: &Value) -> i64 {
    TOKENS
        .iter()
        .map(|f| record[*f].as_i64().unwrap_or(0))
        .sum()
}

#[derive(Clone, Copy)]
pub struct Revisions {
    pub usage: Option<i64>,
    pub timing: Option<i64>,
}

struct TimingFileRevisions {
    data_version: i64,
    total_changes: u64,
    // None means the file may have rows with different revisions.
    files: HashMap<String, Option<i64>>,
}

impl TimingFileRevisions {
    fn read(db: &Connection, data_version: i64) -> Result<Self> {
        let mut statement = db.prepare_cached(
            "SELECT source_file, min(coalesce(parser_rev,1)), max(coalesce(parser_rev,1))
             FROM usage_timings WHERE typeof(source_file)='text' GROUP BY source_file",
        )?;
        let mut rows = statement.query([])?;
        let mut files = HashMap::new();
        while let Some(row) = rows.next()? {
            // Invalid UTF-8 cannot match a file argument. Non-integer revisions
            // go through the exact SQL comparison during revocation.
            if let Ok(file) = row.get_ref(0)?.as_str() {
                let revision = row
                    .get::<_, i64>(1)
                    .ok()
                    .filter(|&rev| row.get::<_, i64>(2).ok() == Some(rev));
                files.insert(file.to_owned(), revision);
            }
        }
        Ok(Self {
            data_version,
            total_changes: db.total_changes(),
            files,
        })
    }

    fn note(&mut self, file: &str, revision: i64) {
        let known = self.files.entry(file.to_owned()).or_insert(Some(revision));
        if *known != Some(revision) {
            *known = None;
        }
    }
}

impl Ledger {
    pub(crate) fn open_read_only(
        path: &Path,
        clock: Clock,
    ) -> std::result::Result<Self, ReadOpenError> {
        match path.metadata() {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(ReadOpenError::Missing)
            }
            Err(error) => return Err(ReadOpenError::Unavailable(error.into())),
            Ok(_) => {}
        }
        let db =
            Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
                ReadOpenError::Unavailable(crate::startup_error::sqlite_open_error(e, path, false))
            })?;
        let ledger = Self::from_connection(db, clock, path);
        Ok(ledger)
    }

    pub(crate) fn check_read_version(&self) -> std::result::Result<(), ReadOpenError> {
        let version = self
            .db
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(|e| ReadOpenError::Unavailable(e.into()))?;
        if version != LEDGER_VERSION {
            return Err(ReadOpenError::Version(version));
        }
        Ok(())
    }

    pub fn open(path: &Path, clock: Clock) -> Result<Self> {
        if path != Path::new(":memory:") {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let db = Connection::open(path)
            .map_err(|e| crate::startup_error::sqlite_open_error(e, path, true))?;
        let classify = |e: rusqlite::Error| {
            let system_error = if matches!(
                e.sqlite_error_code(),
                Some(rusqlite::ErrorCode::CannotOpen | rusqlite::ErrorCode::SystemIoFailure)
            ) {
                // This connection is still open and the failing operation was its last call.
                let errno = unsafe { rusqlite::ffi::sqlite3_system_errno(db.handle()) };
                (errno != 0).then(|| std::io::Error::from_raw_os_error(errno))
            } else {
                None
            };
            Error::sqlite(e, system_error.as_ref())
        };
        let current: i64 = db
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(classify)?;
        if current > LEDGER_VERSION {
            let code = crate::startup_error::StartupCode::LedgerTooNew.as_str();
            return Err(Error(format!(
                "{code}:{current}:{LEDGER_VERSION}: 账本结构版本 {current} 高于本程序支持的 {LEDGER_VERSION}，拒绝以旧版本写入"
            )));
        }
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;").map_err(classify)?;
        if current < 5 {
            let transaction = db.unchecked_transaction()?;
            // ECMAScript template literals normalize source CRLF to LF.
            transaction.execute_batch(&include_str!("schema.sql").replace("\r\n", "\n"))?;
            for (version, table, name, kind) in [
                (2, "usage_records", "cache_write_5m_tokens", "INTEGER"),
                (2, "usage_records", "cache_write_1h_tokens", "INTEGER"),
                (3, "usage_records", "ended_at", "TEXT"),
                (4, "usage_records", "source_file", "TEXT"),
                (4, "usage_records", "parser_rev", "INTEGER"),
                (4, "ingest_runs", "counts", "TEXT"),
                (5, "usage_records", "provider", "TEXT"),
            ] {
                if current < version
                    && !rows(&transaction, &format!("PRAGMA table_info({table})"), &[])?
                        .iter()
                        .any(|r| r["name"] == name)
                {
                    transaction
                        .execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {name} {kind}"))?;
                }
            }
            transaction.execute_batch("CREATE INDEX IF NOT EXISTS idx_usage_file ON usage_records(source_file, active); PRAGMA user_version=5;")?;
            transaction.commit()?;
            if path != Path::new(":memory:") {
                crate::diagnostics::RuntimeLog::new(path.parent().unwrap_or(Path::new(".")), None)
                    .write("INFO", "ledger", &format!("migration schema={current}->5"));
            }
        }
        if current < 6 {
            if current > 0 && path != Path::new(":memory:") {
                // VACUUM INTO includes committed WAL content; never copy the live main file.
                let date = clock.iso();
                let mut suffix = 0;
                let backup = loop {
                    let backup = path.with_file_name(format!(
                        "ledger-v5-{}-{}-{suffix}.db",
                        &date[..10],
                        clock.millis()
                    ));
                    if !backup.exists() {
                        break backup;
                    }
                    suffix += 1;
                };
                db.execute("VACUUM INTO ?", [backup.to_string_lossy().as_ref()])?;
            }
            let transaction = db.unchecked_transaction()?;
            transaction.execute_batch(include_str!("timings.sql"))?;
            transaction.execute_batch("PRAGMA user_version=6;")?;
            transaction.commit()?;
        }
        if current < LEDGER_VERSION {
            ingest_cache::migrate(&db, path, &clock, current > 0)?;
        }
        Ok(Self::from_connection(db, clock, path))
    }

    fn from_connection(db: Connection, clock: Clock, path: &Path) -> Self {
        Self {
            db,
            clock,
            prices: EffectivePrices::load(
                (path != Path::new(":memory:"))
                    .then(|| path.parent())
                    .flatten(),
            ),
            prune_cache: Default::default(),
            timing_revisions: Default::default(),
        }
    }

    fn write_timing(
        &self,
        record: &Value,
        file: Option<&str>,
        revision: Option<i64>,
        usage_unchanged: bool,
    ) -> Result<bool> {
        let old = cached_rows(
            &self.db,
            "SELECT * FROM usage_timings WHERE record_key=?",
            &[record["record_key"].clone()],
        )?
        .pop();
        let source_file = file.map_or_else(
            || {
                old.as_ref()
                    .map_or(Value::Null, |r| r["source_file"].clone())
            },
            |f| json!(f),
        );
        // The v6 column retains its original name but stores only TIMING_REV.
        let timing_rev = revision.map_or_else(
            || {
                old.as_ref()
                    .map_or(Value::Null, |r| r["parser_rev"].clone())
            },
            |r| json!(r),
        );
        // Both metrics belong to one usage payload and one first-output instant.
        // Changed usage must replace its timing even in the same file and revision.
        let retain_old = usage_unchanged
            && old.as_ref().is_some_and(|row| {
                let old_revision = row["parser_rev"].as_i64().unwrap_or(1);
                revision.unwrap_or(old_revision) == old_revision
                    && source_file == row["source_file"]
                    && (row["status"] == "completed"
                        || !record["timing"].is_object()
                        || ["ttft_ms", "generation_ms", "duration_ms"]
                            .iter()
                            .any(|metric| {
                                !row[*metric].is_null() && record["timing"][*metric].is_null()
                            }))
            });
        if record["kind"].as_str().unwrap_or("event") != "event"
            || (!record["timing"].is_object() && !retain_old)
        {
            if old.is_some() {
                self.db
                    .prepare_cached(DELETE_TIMING)?
                    .execute([record["record_key"].as_str()])?;
            }
            return Ok(false);
        }
        let mut timing = if retain_old {
            old.as_ref().unwrap().clone()
        } else {
            record["timing"].clone()
        };
        if timing["status"].is_null() {
            timing["status"] = json!("unknown");
        }
        let fields = [
            "ttft_ms",
            "ttft_method",
            "generation_ms",
            "generation_method",
            "duration_ms",
            "duration_method",
            "timing_output_tokens",
            "scope",
            "status",
        ];
        let values: Vec<Value> = fields.iter().map(|key| timing[*key].clone()).collect();
        let hash = format!("{:x}", Sha256::digest(serde_json::to_vec(&values)?));
        let mut args = vec![record["record_key"].clone(), record["source"].clone()];
        args.extend(values);
        args.extend([source_file, timing_rev, json!(hash)]);
        let written = self.db.prepare_cached("INSERT INTO usage_timings(record_key,source,ttft_ms,ttft_method,generation_ms,generation_method,duration_ms,duration_method,timing_output_tokens,scope,status,source_file,parser_rev,timing_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(record_key) DO UPDATE SET source=excluded.source,ttft_ms=excluded.ttft_ms,ttft_method=excluded.ttft_method,generation_ms=excluded.generation_ms,generation_method=excluded.generation_method,duration_ms=excluded.duration_ms,duration_method=excluded.duration_method,timing_output_tokens=excluded.timing_output_tokens,scope=excluded.scope,status=excluded.status,source_file=excluded.source_file,parser_rev=excluded.parser_rev,timing_hash=excluded.timing_hash WHERE usage_timings.timing_hash!=excluded.timing_hash OR usage_timings.source_file IS NOT excluded.source_file OR usage_timings.parser_rev IS NOT excluded.parser_rev")?
            .execute(params_from_iter(args.iter().map(sql_value)))?;
        Ok(written > 0)
    }

    fn supersede(&self, record: &Value, id: i64, stats: &mut Value) -> Result<()> {
        if let Some(replaces) = record["replaces"].as_array() {
            for key in replaces {
                if key.as_str().is_some_and(|k| !k.is_empty()) && *key != record["record_key"] {
                    let count = self.db.prepare_cached("UPDATE usage_records SET active=0,superseded_by=? WHERE record_key=? AND active=1")?
                        .execute(params![id, key.as_str()])?;
                    if count > 0 {
                        self.db
                            .prepare_cached(DELETE_TIMING)?
                            .execute([key.as_str()])?;
                        increment(&mut stats["counts"], "replaced");
                    }
                }
            }
        }
        Ok(())
    }

    #[cfg(test)]
    pub fn batch(
        &self,
        records: &[Value],
        file: Option<&str>,
        revision: Option<i64>,
        elsewhere: &[String],
        price: impl Fn(&Value) -> Value,
    ) -> Result<Value> {
        let timing_revision = records
            .first()
            .and_then(|r| r["source"].as_str())
            .and_then(super::adapters::timing_rev);
        self.batch_with_timing_revision(records, file, revision, timing_revision, elsewhere, price)
    }

    #[cfg(test)]
    pub fn batch_with_timing_revision(
        &self,
        records: &[Value],
        file: Option<&str>,
        usage_revision: Option<i64>,
        timing_revision: Option<i64>,
        elsewhere: &[String],
        price: impl Fn(&Value) -> Value,
    ) -> Result<Value> {
        self.batch_cancellable(
            records,
            file,
            Revisions {
                usage: usage_revision,
                timing: timing_revision,
            },
            elsewhere,
            price,
            || false,
        )
    }

    #[cfg(test)]
    pub fn batch_cancellable(
        &self,
        records: &[Value],
        file: Option<&str>,
        revisions: Revisions,
        elsewhere: &[String],
        price: impl Fn(&Value) -> Value,
        cancelled: impl Fn() -> bool,
    ) -> Result<Value> {
        self.batch_with_commit(
            records,
            (file, revisions, elsewhere),
            price,
            cancelled,
            |_| Ok(()),
        )
    }

    pub(in crate::stats) fn batch_with_commit(
        &self,
        records: &[Value],
        file_rules: (Option<&str>, Revisions, &[String]),
        price: impl Fn(&Value) -> Value,
        cancelled: impl Fn() -> bool,
        before_commit: impl FnOnce(&Transaction<'_>) -> Result<()>,
    ) -> Result<Value> {
        let (file, revisions, elsewhere) = file_rules;
        let revision = revisions.usage;
        let transaction = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let before = self.db.total_changes();
        let mut timing_upserted = false;
        let mut stats = json!({"attempted":0,"inserted":0,"updated":0,"unchanged":0,"rejected":0,"counts":{"relabeled":0,"reactivated":0,"replaced":0,"deactivated":0,"vanished":0,"rev_corrections":0,"cumulative_decrease":0},"anomalies":[]});
        let mut produced = HashSet::new();
        for record in records {
            if cancelled() {
                return Err(Error("cancelled".into()));
            }
            increment(&mut stats, "attempted");
            if let Some(key) = record["record_key"].as_str().filter(|s| !s.is_empty()) {
                produced.insert(key.to_owned());
            }
            if let Some(reason) = validate(record) {
                increment(&mut stats, "rejected");
                anomaly(
                    &mut stats,
                    format!(
                        "rejected: {} — {reason}",
                        record["record_key"].as_str().unwrap_or("(no key)")
                    ),
                );
                continue;
            }
            let old = cached_rows(
                &self.db,
                "SELECT * FROM usage_records WHERE record_key=?",
                &[record["record_key"].clone()],
            )?
            .pop();
            let mut effective = record.clone();
            if let Some(old) = &old {
                if effective["ended_at"].is_null() {
                    effective["ended_at"] = old["ended_at"].clone();
                }
            }
            effective["kind"] = json!(record["kind"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or("event"));
            let hash = payload_hash(&effective);
            let price = price(&effective);
            if let Some(old) = &old {
                let id = old["id"].as_i64().unwrap();
                if old["active"] == 0 {
                    if !old["superseded_by"].is_null() {
                        anomaly(
                            &mut stats,
                            format!(
                                "superseded_reproduced: {}",
                                record["record_key"].as_str().unwrap()
                            ),
                        );
                        continue;
                    }
                    self.db
                        .prepare_cached("UPDATE usage_records SET active=1 WHERE id=?")?
                        .execute([id])?;
                    increment(&mut stats["counts"], "reactivated");
                }
                if old["content_hash"] == hash {
                    if !record["project_key"].is_null()
                        && record["project_key"] != old["project_key"]
                    {
                        self.db
                            .prepare_cached("UPDATE usage_records SET project_key=? WHERE id=?")?
                            .execute(params![sql_value(&record["project_key"]), id])?;
                        increment(&mut stats["counts"], "relabeled");
                    } else {
                        increment(&mut stats, "unchanged");
                    }
                    if file.is_some_and(|f| old["source_file"] != f)
                        || revision.is_some_and(|v| old["parser_rev"] != v)
                    {
                        self.db.prepare_cached("UPDATE usage_records SET source_file=coalesce(?,source_file),parser_rev=coalesce(?,parser_rev) WHERE id=?")?
                            .execute(params![file, revision, id])?;
                    }
                    self.supersede(record, id, &mut stats)?;
                    timing_upserted |= self.write_timing(record, file, revisions.timing, true)?;
                    continue;
                }
                if old["kind"] == "cumulative" && gross(record) < gross(old) {
                    if revision.is_some_and(|r| r != old["parser_rev"].as_i64().unwrap_or(1)) {
                        increment(&mut stats["counts"], "rev_corrections");
                    } else {
                        increment(&mut stats["counts"], "cumulative_decrease");
                        anomaly(
                            &mut stats,
                            format!(
                                "cumulative_decrease: {} — {} → {}",
                                record["record_key"].as_str().unwrap(),
                                gross(old),
                                gross(record)
                            ),
                        );
                        continue;
                    }
                }
                let mut args = vec![json!(hash)];
                args.extend(FIELDS.iter().map(|f| match *f {
                    "source_file" => file.map_or(old["source_file"].clone(), |s| json!(s)),
                    "parser_rev" => revision.map_or(old["parser_rev"].clone(), |s| json!(s)),
                    "project_key" if effective[*f].is_null() => old[*f].clone(),
                    _ => effective[*f].clone(),
                }));
                args.extend([
                    price["price_version"].clone(),
                    price["cost_micros"].clone(),
                    price["price_source"].clone(),
                    json!(id),
                ]);
                self.db
                    .prepare_cached(&UPDATE_USAGE)?
                    .execute(params_from_iter(args.iter().map(sql_value)))?;
                increment(&mut stats, "updated");
                self.supersede(record, id, &mut stats)?;
                timing_upserted |= self.write_timing(record, file, revisions.timing, false)?;
            } else {
                let mut args = vec![
                    record["record_key"].clone(),
                    json!(hash),
                    record["source"].clone(),
                ];
                args.extend(FIELDS.iter().map(|f| match *f {
                    "source_file" => json!(file),
                    "parser_rev" => json!(revision),
                    _ => effective[*f].clone(),
                }));
                args.extend([
                    price["price_version"].clone(),
                    price["cost_micros"].clone(),
                    price["price_source"].clone(),
                ]);
                self.db
                    .prepare_cached(&INSERT_USAGE)?
                    .execute(params_from_iter(args.iter().map(sql_value)))?;
                increment(&mut stats, "inserted");
                self.supersede(record, self.db.last_insert_rowid(), &mut stats)?;
                timing_upserted |= self.write_timing(record, file, revisions.timing, false)?;
            }
        }
        if let Some(file) = file.filter(|_| !produced.is_empty() || !elsewhere.is_empty()) {
            let mut vanished = 0;
            for row in cached_rows(&self.db, "SELECT id,record_key,parser_rev FROM usage_records WHERE source_file=? AND active=1", &[json!(file)])? {
                let key = row["record_key"].as_str().unwrap();
                if produced.contains(key) || elsewhere.iter().any(|s| s == key) { continue; }
                if revision.is_some_and(|r| r != row["parser_rev"].as_i64().unwrap_or(1)) {
                    self.db.prepare_cached("UPDATE usage_records SET active=0 WHERE id=?")?
                        .execute([row["id"].as_i64().unwrap()])?;
                    self.db.prepare_cached(DELETE_TIMING)?.execute([key])?;
                    increment(&mut stats["counts"], "deactivated");
                } else { vanished += 1; }
            }
            stats["counts"]["vanished"] = json!(vanished);
            if vanished > 0 {
                anomaly(
                    &mut stats,
                    format!("vanished: {file} — {vanished} 条记录不再出现，保留原值"),
                );
            }
        }
        if cancelled() {
            return Err(Error("cancelled".into()));
        }
        let mut timing_revisions = None;
        if let (Some(file), Some(revision)) = (file, revisions.timing) {
            // A successful new timing revision may revoke timings even when the empty-output
            // guard deliberately preserves the historical usage rows.
            let data_version = self
                .db
                .prepare_cached("PRAGMA data_version")?
                .query_row([], |row| row.get(0))?;
            let previous = self.timing_revisions.borrow_mut().take();
            let current = match previous {
                Some(mut previous)
                    if previous.data_version == data_version
                        && previous.total_changes == before =>
                {
                    // Every upsert in this batch uses the supplied file and revision.
                    // Deletions and moves can only remove members of other groups.
                    if timing_upserted {
                        previous.note(file, revision);
                    }
                    previous
                }
                _ => TimingFileRevisions::read(&self.db, data_version)?,
            };
            if current
                .files
                .get(file)
                .is_some_and(|known| *known != Some(revision))
            {
                for row in cached_rows(&self.db,"SELECT record_key FROM usage_timings WHERE source_file=? AND coalesce(parser_rev,1)!=?",&[json!(file),json!(revision)])? {
                    let key=row["record_key"].as_str().unwrap();
                    if !elsewhere.iter().any(|other|other==key) {
                        self.db.prepare_cached(DELETE_TIMING)?.execute([key])?;
                    }
                }
            }
            timing_revisions = Some(current);
        }
        before_commit(&transaction)?;
        if cancelled() {
            return Err(Error("cancelled".into()));
        }
        transaction.commit()?;
        if let Some(mut current) = timing_revisions {
            current.total_changes = self.db.total_changes();
            *self.timing_revisions.borrow_mut() = Some(current);
        }
        Ok(stats)
    }

    #[cfg(test)]
    pub fn begin_run(&self) -> Result<i64> {
        self.begin_run_triggered(None)
    }

    pub(crate) fn begin_run_triggered(&self, trigger: Option<&str>) -> Result<i64> {
        self.db.execute(
            "UPDATE ingest_runs SET status='abandoned' WHERE status='running'",
            [],
        )?;
        self.db.execute(
            "INSERT INTO ingest_runs(started_at,status,counts) VALUES (?,'running',?)",
            params![
                self.clock.millis() / 1000,
                trigger.map(|name| json!({format!("sync_trigger.{name}"):1}).to_string())
            ],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    pub fn finish_run(&self, id: i64, status: &str, stats: &Value) -> Result<()> {
        let notes = stats["anomalies"]
            .as_array()
            .filter(|a| !a.is_empty())
            .map(|_| stats["anomalies"].to_string());
        let counts = stats["counts"].as_object().map(|counts| {
            let order = [
                "read_failed",
                "bad_lines",
                "bad_fields",
                "bad_times",
                "zero_usage",
                "cross_file_copies",
                "relabeled",
                "reactivated",
                "replaced",
                "deactivated",
                "vanished",
                "rev_corrections",
                "cumulative_decrease",
            ];
            format!(
                "{{{}}}",
                order
                    .iter()
                    .copied()
                    .chain(counts.keys().map(String::as_str).filter(|key| {
                        key.starts_with("discovery.") || key.starts_with("sync_source.")
                    }))
                    .filter_map(|key| counts.get(key).map(|value| format!("\"{key}\":{value}")))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        });
        let transaction = self.db.unchecked_transaction()?;
        transaction.execute("UPDATE ingest_runs SET finished_at=?1,status=?2,attempted=?3,inserted=?4,updated=?5,unchanged=?6,rejected=?7,notes=?8,counts=CASE WHEN counts IS NULL THEN ?9 ELSE json_patch(counts,coalesce(?9,'{}')) END WHERE id=?10", params![self.clock.millis()/1000,status,sql_value(&stats["attempted"]),sql_value(&stats["inserted"]),sql_value(&stats["updated"]),sql_value(&stats["unchanged"]),sql_value(&stats["rejected"]),notes,counts,id])?;
        if let (Some(parsed), Some(cached), Some(skipped)) = (
            stats["parsedFiles"].as_i64(),
            stats["cachedFiles"].as_i64(),
            stats["skippedFiles"].as_i64(),
        ) {
            transaction.execute(
                "INSERT INTO ingest_run_files (run_id,parsed_files,cached_files,skipped_files) VALUES (?,?,?,?)",
                params![id, parsed, cached, skipped],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    #[cfg(test)]
    pub fn fail_run(&self, id: i64, message: &str) -> Result<()> {
        self.fail_run_with_results(id, message, None)
    }

    pub(crate) fn fail_run_with_results(
        &self,
        id: i64,
        message: &str,
        results: Option<&Value>,
    ) -> Result<()> {
        self.db.execute(
            "UPDATE ingest_runs SET finished_at=?1,status='failed',notes=?2,
             counts=CASE WHEN ?3 IS NULL THEN counts ELSE json_patch(coalesce(counts,'{}'),?3) END WHERE id=?4",
            params![
                self.clock.millis() / 1000,
                json!([format!("run_failed: {message}")]).to_string(),
                results.map(Value::to_string),
                id
            ],
        )?;
        Ok(())
    }

    #[cfg(test)]
    pub fn reprice(&self, version: &str, price: impl Fn(&Value) -> Value) -> Result<usize> {
        self.reprice_cancellable(version, price, || false)
    }
    pub fn reprice_cancellable(
        &self,
        version: &str,
        price: impl Fn(&Value) -> Value,
        cancelled: impl Fn() -> bool,
    ) -> Result<usize> {
        let transaction = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let candidates = rows(&self.db, "SELECT * FROM usage_records WHERE active=1 AND (price_version IS NULL OR price_version!=?)", &[json!(version)])?;
        for row in &candidates {
            if cancelled() {
                return Err(Error("cancelled".into()));
            }
            let p = price(row);
            self.db.execute(
                "UPDATE usage_records SET price_version=?,cost_micros=?,price_source=? WHERE id=?",
                params![
                    p["price_version"].as_str().unwrap_or(version),
                    sql_value(&p["cost_micros"]),
                    sql_value(&p["price_source"]),
                    sql_value(&row["id"])
                ],
            )?;
        }
        if !candidates.is_empty() {
            self.db.execute("INSERT INTO pricing_snapshot(version,catalog_json,verified_at,created_at) VALUES (?,?,?,unixepoch()) ON CONFLICT(version) DO UPDATE SET created_at=unixepoch()", params![version,json!({"version":version}).to_string(),&self.clock.iso()[..10]])?;
        }
        if cancelled() {
            return Err(Error("cancelled".into()));
        }
        transaction.commit()?;
        Ok(candidates.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn fresh_ledger_inserts_then_touches_without_duplicates() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let record = json!({"record_key":"claude|a", "source":"claude", "observed_at":"2026-01-15T12:00:00.000Z", "input_tokens":12});
        let first = ledger
            .batch(
                std::slice::from_ref(&record),
                Some("synthetic.jsonl"),
                Some(1),
                &[],
                |_| Value::Null,
            )
            .unwrap();
        assert_eq!(first["inserted"], 1);
        let second = ledger
            .batch(&[record], Some("synthetic.jsonl"), Some(1), &[], |_| {
                Value::Null
            })
            .unwrap();
        assert_eq!(second["unchanged"], 1);
    }

    #[test]
    fn unchanged_record_without_timing_does_not_attempt_a_delete() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let record = json!({"record_key":"codex|plain","source":"codex","observed_at":"2026-01-15T12:00:00.000Z","input_tokens":12});
        let mut timed = record.clone();
        timed["record_key"] = json!("codex|timed");
        timed["timing"] = json!({"duration_ms":1000,"scope":"request","status":"completed"});
        let file = Some("synthetic.jsonl");
        ledger
            .batch(&[record.clone(), timed], file, Some(1), &[], |_| {
                Value::Null
            })
            .unwrap();
        let query = "SELECT * FROM usage_timings ORDER BY record_key";
        let before = rows(&ledger.db, query, &[]).unwrap();
        assert_eq!(before.len(), 1);

        // The transaction opens before pricing. Even a DELETE matching no rows fails here.
        let result = ledger.batch(&[record], file, Some(1), &[], |_| {
            ledger.db.execute_batch("PRAGMA query_only=ON").unwrap();
            Value::Null
        });
        ledger.db.execute_batch("PRAGMA query_only=OFF").unwrap();
        assert_eq!(result.unwrap()["unchanged"], 1);
        assert_eq!(rows(&ledger.db, query, &[]).unwrap(), before);
    }

    #[test]
    fn timing_only_progress_and_changed_usage_replace_whole_groups() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let mut record = json!({
            "record_key":"codex|timed","source":"codex","observed_at":"2026-01-15T12:00:00.000Z",
            "input_tokens":12,"output_tokens":4,
            "timing":{"ttft_ms":300,"ttft_method":"log_timestamps","scope":"request","status":"partial","timing_output_tokens":4}
        });
        let write = |record: &Value| {
            ledger
                .batch(
                    std::slice::from_ref(record),
                    Some("synthetic.jsonl"),
                    Some(1),
                    &[],
                    |_| Value::Null,
                )
                .unwrap()
        };
        let timing = || {
            rows(&ledger.db, "SELECT * FROM usage_timings", &[])
                .unwrap()
                .pop()
                .unwrap()
        };
        assert_eq!(write(&record)["inserted"], 1);
        assert_eq!(timing()["status"], "partial");

        record["timing"]["status"] = json!("completed");
        record["timing"]["generation_ms"] = json!(700);
        record["timing"]["ttft_ms"] = json!(350);
        assert_eq!(write(&record)["unchanged"], 1);
        assert_eq!(timing()["ttft_ms"], 350);
        assert_eq!(timing()["generation_ms"], 700);

        record["output_tokens"] = json!(9);
        record["timing"] = json!({
            "duration_ms":1600,"duration_method":"client_reported","scope":"turn",
            "status":"partial","timing_output_tokens":9
        });
        assert_eq!(write(&record)["updated"], 1);
        let current = timing();
        assert_eq!(current["ttft_ms"], Value::Null);
        assert_eq!(current["ttft_method"], Value::Null);
        assert_eq!(current["generation_ms"], Value::Null);
        assert_eq!(current["duration_ms"], 1600);
        assert_eq!(current["status"], "partial");
        assert_eq!(current["scope"], "turn");
        assert_eq!(current["timing_output_tokens"], 9);
    }

    #[test]
    fn timing_revocation_refreshes_after_local_or_external_writes() {
        for external in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let path = temp.path().join("ledger.db");
            let ledger = Ledger::open(&path, Clock::Fixed(1768478400000)).unwrap();
            let record = json!({
                "record_key":"codex|timed","source":"codex","observed_at":"2026-01-15T12:00:00.000Z",
                "input_tokens":12,"timing":{"duration_ms":1000,"scope":"request"}
            });
            ledger
                .batch(&[record], Some("usage.jsonl"), Some(1), &[], |_| {
                    Value::Null
                })
                .unwrap();
            let other = external.then(|| Connection::open(&path).unwrap());
            other
                .as_ref()
                .unwrap_or(&ledger.db)
                .execute(
                    "UPDATE usage_timings SET source_file='timing.jsonl', parser_rev=NULL",
                    [],
                )
                .unwrap();
            ledger
                .batch_with_timing_revision(
                    &[],
                    Some("timing.jsonl"),
                    Some(1),
                    Some(2),
                    &[],
                    |_| Value::Null,
                )
                .unwrap();
            assert!(rows(&ledger.db, "SELECT * FROM usage_timings", &[])
                .unwrap()
                .is_empty());
            let usage = rows(
                &ledger.db,
                "SELECT active,source_file FROM usage_records",
                &[],
            )
            .unwrap();
            assert_eq!(usage, [json!({"active":1,"source_file":"usage.jsonl"})]);
        }
    }

    #[test]
    fn timing_revocation_sees_files_written_after_the_first_scan() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let mut record = json!({
            "record_key":"codex|seed","source":"codex","observed_at":"2026-01-15T12:00:00.000Z",
            "input_tokens":12,"timing":{"duration_ms":1000,"scope":"request"}
        });
        ledger
            .batch(&[record.clone()], Some("seed.jsonl"), Some(1), &[], |_| {
                Value::Null
            })
            .unwrap();
        record["record_key"] = json!("codex|later");
        ledger
            .batch(&[record], Some("later.jsonl"), Some(1), &[], |_| {
                Value::Null
            })
            .unwrap();
        let revoke = |elsewhere: &[String]| {
            ledger
                .batch_with_timing_revision(
                    &[],
                    Some("later.jsonl"),
                    Some(1),
                    Some(2),
                    elsewhere,
                    |_| Value::Null,
                )
                .unwrap();
            rows(
                &ledger.db,
                "SELECT record_key FROM usage_timings ORDER BY record_key",
                &[],
            )
            .unwrap()
        };
        assert_eq!(
            revoke(&["codex|later".into()]),
            [
                json!({"record_key":"codex|later"}),
                json!({"record_key":"codex|seed"})
            ]
        );
        assert_eq!(revoke(&[]), [json!({"record_key":"codex|seed"})]);
    }

    #[test]
    fn file_revision_reactivates_usage_but_same_revision_refuses_a_decrease() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let mut cumulative = json!({"record_key":"codex|cumulative","kind":"cumulative","source":"codex","observed_at":"2026-01-15T12:00:00.000Z","input_tokens":12});
        let mut anchor = cumulative.clone();
        anchor["record_key"] = json!("codex|anchor");
        let write = |records: &[Value], revision| {
            ledger
                .batch(
                    records,
                    Some("synthetic.jsonl"),
                    Some(revision),
                    &[],
                    |_| Value::Null,
                )
                .unwrap()
        };
        assert_eq!(
            write(&[anchor.clone(), cumulative.clone()], 1)["inserted"],
            2
        );
        assert_eq!(write(&[anchor], 2)["counts"]["deactivated"], 1);
        let result = write(&[cumulative.clone()], 2);
        assert_eq!(result["counts"]["reactivated"], 1);
        assert_eq!(result["unchanged"], 1);
        cumulative["input_tokens"] = json!(7);
        let result = write(&[cumulative], 2);
        assert_eq!(result["counts"]["cumulative_decrease"], 1);
        assert_eq!(result["updated"], 0);
        assert_eq!(
            result["anomalies"][0],
            "cumulative_decrease: codex|cumulative — 12 → 7"
        );
        let saved = rows(&ledger.db, "SELECT active,input_tokens,parser_rev FROM usage_records WHERE record_key='codex|cumulative'", &[]).unwrap();
        assert_eq!(
            saved,
            [json!({"active":1,"input_tokens":12,"parser_rev":2})]
        );
    }

    #[test]
    fn writer_and_migrations_match_node() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../tests/fixtures/parity/ledger.json"))
                .unwrap();
        let expected: Vec<Value> = include_str!("../../../tests/golden/ledger.jsonl")
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let run = ledger.begin_run().unwrap();
        for (index, batch) in fixture["batches"].as_array().unwrap().iter().enumerate() {
            let records: Vec<Value> = batch["records"]
                .as_array()
                .unwrap()
                .iter()
                .map(|overrides| {
                    let mut r = fixture["base"].clone();
                    for (key, value) in overrides.as_object().unwrap() {
                        r[key] = value.clone();
                    }
                    r
                })
                .collect();
            let elsewhere: Vec<String> = batch["elsewhere"]
                .as_array()
                .map(|a| a.iter().map(|s| s.as_str().unwrap().into()).collect())
                .unwrap_or_default();
            let actual = ledger.batch(&records, batch["file"].as_str(), batch["rev"].as_i64(), &elsewhere, |r| json!({"cost_micros":r["input_tokens"].as_i64().unwrap_or(0)*if r["ended_at"].is_null() {7} else {2},"price_version":"test-v1","price_source":"test:time"})).unwrap();
            let wanted = expected
                .iter()
                .find(|r| r["type"] == "batch" && r["index"] == index)
                .unwrap();
            assert_eq!(actual, wanted["expected"], "batch {index}");
        }
        for entry in expected.iter().filter(|r| r["type"] == "identity") {
            assert_eq!(
                payload_hash(&entry["record"]),
                entry["expected"].as_str().unwrap(),
                "{entry}"
            );
            assert_eq!(
                payload_input(&entry["record"])
                    .as_bytes()
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>(),
                entry["canonical_utf8_hex"].as_str().unwrap()
            );
        }
        let mut actual = rows(&ledger.db,"SELECT u.*,s.record_key AS superseded_key FROM usage_records u LEFT JOIN usage_records s ON s.id=u.superseded_by ORDER BY u.record_key",&[]).unwrap();
        for row in &mut actual {
            row.as_object_mut().unwrap().remove("id");
            row["ingested_at"] = json!("<volatile>");
            row["superseded_by"] = row["superseded_key"].clone();
            row.as_object_mut().unwrap().remove("superseded_key");
        }
        let wanted: Vec<_> = expected
            .iter()
            .filter(|r| r["type"] == "ledger_row")
            .map(|r| r["expected"].clone())
            .collect();
        assert_eq!(actual, wanted);
        ledger.finish_run(run,"ok", &json!({"attempted":1,"inserted":1,"updated":0,"unchanged":0,"rejected":0,"counts":{"vanished":1},"anomalies":["synthetic"]})).unwrap();
        let run = ledger.begin_run().unwrap();
        ledger.fail_run(run, "synthetic").unwrap();
        ledger.begin_run().unwrap();
        ledger.begin_run().unwrap();
        let runs = rows(&ledger.db, "SELECT * FROM ingest_runs ORDER BY id", &[]).unwrap();
        assert_eq!(runs[0]["started_at"], 1768478400_i64);
        assert_eq!(runs[1]["notes"], "[\"run_failed: synthetic\"]");
        assert_eq!(runs[2]["status"], "abandoned");
        assert_eq!(
            ledger.last_run().unwrap(),
            expected.iter().find(|r| r["type"] == "run").unwrap()["expected"]
        );
        assert_eq!(ledger.reprice("test-v2", |r| json!({"cost_micros":r["input_tokens"].as_i64().unwrap()*11,"price_version":"test-v2","price_source":"test:v2"})).unwrap(), expected.iter().find(|r|r["fn"]=="reprice").unwrap()["expected"].as_u64().unwrap() as usize);
        assert_eq!(
            ledger
                .reprice("test-v2", |_| panic!("must not reprice twice"))
                .unwrap(),
            0
        );
        assert_eq!(json!(rows(&ledger.db,"SELECT record_key,price_version,cost_micros,price_source FROM usage_records ORDER BY record_key",&[]).unwrap()),expected.iter().find(|r|r["fn"]=="reprice_rows").unwrap()["expected"]);
        let mut snapshots = rows(
            &ledger.db,
            "SELECT * FROM pricing_snapshot ORDER BY version",
            &[],
        )
        .unwrap();
        for row in &mut snapshots {
            row["created_at"] = json!("<volatile>");
        }
        assert_eq!(
            json!(snapshots),
            expected
                .iter()
                .find(|r| r["fn"] == "pricing_snapshot")
                .unwrap()["expected"]
        );

        for line in include_str!("../../../tests/golden/migrations.jsonl").lines() {
            let golden: Value = serde_json::from_str(line).unwrap();
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("ledger.db");
            let initial = Connection::open(&path).unwrap();
            let sql = match golden["version"].as_i64().unwrap() {
                1 => include_str!("../../../tests/fixtures/parity/v1.sql"),
                2 => include_str!("../../../tests/fixtures/parity/v2.sql"),
                3 => include_str!("../../../tests/fixtures/parity/v3.sql"),
                _ => include_str!("../../../tests/fixtures/parity/v4.sql"),
            };
            initial.execute_batch(sql).unwrap();
            drop(initial);
            let migrated = Ledger::open(&path, Clock::Fixed(1768478400000)).unwrap();
            let timing_columns =
                rows(&migrated.db, "PRAGMA table_info(usage_timings)", &[]).unwrap();
            for name in ["duration_ms", "duration_method"] {
                assert!(timing_columns.iter().any(|r| r["name"] == name));
            }
            // Exclude the Rust-only timing and ingest cache tables from the v5 schema comparison.
            let schema = rows(&migrated.db,"SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND tbl_name NOT IN ('usage_timings','ingest_files','ingest_file_replaces','ingest_pending_sources','ingest_run_files') ORDER BY type,name",&[]).unwrap();
            assert_eq!(
                json!(schema),
                golden["schema"],
                "schema v{}",
                golden["version"]
            );
            for name in [
                "usage_records",
                "ingest_runs",
                "legacy_records",
                "pricing_snapshot",
            ] {
                let mut actual = rows(
                    &migrated.db,
                    &format!("SELECT * FROM {name} ORDER BY 1"),
                    &[],
                )
                .unwrap();
                for row in &mut actual {
                    for field in ["ingested_at", "imported_at", "created_at"] {
                        if row.get(field).is_some() {
                            row[field] = json!("<volatile>");
                        }
                    }
                }
                assert_eq!(
                    json!(actual),
                    golden["tables"][name],
                    "v{} {name}",
                    golden["version"]
                );
            }
        }
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("future.db");
        Connection::open(&path)
            .unwrap()
            .execute_batch("PRAGMA user_version=8")
            .unwrap();
        assert!(Ledger::open(&path, Clock::System)
            .err()
            .unwrap()
            .0
            .contains("高于"));
    }

    #[test]
    fn cancellation_rolls_back_whole_file_and_reprice() {
        use std::cell::Cell;
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let record = json!({"record_key":"a","source":"claude","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":10});
        let cancelled = Cell::new(false);
        let result = ledger.batch_cancellable(
            std::slice::from_ref(&record),
            Some("synthetic.jsonl"),
            Revisions {
                usage: Some(1),
                timing: None,
            },
            &[],
            |_| {
                cancelled.set(true);
                Value::Null
            },
            || cancelled.get(),
        );
        assert_eq!(result.unwrap_err().0, "cancelled");
        assert_eq!(
            rows(&ledger.db, "SELECT * FROM usage_records", &[])
                .unwrap()
                .len(),
            0
        );
        ledger
            .batch(&[record], Some("synthetic.jsonl"), Some(1), &[], |_| {
                Value::Null
            })
            .unwrap();
        cancelled.set(false);
        let result = ledger.reprice_cancellable(
            "new",
            |_| {
                cancelled.set(true);
                json!({"cost_micros":123,"price_version":"new","price_source":"synthetic"})
            },
            || cancelled.get(),
        );
        assert_eq!(result.unwrap_err().0, "cancelled");
        assert!(
            rows(&ledger.db, "SELECT cost_micros FROM usage_records", &[]).unwrap()[0]
                ["cost_micros"]
                .is_null()
        );
    }
}
