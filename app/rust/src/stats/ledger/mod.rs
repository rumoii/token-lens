use super::{
    clock::Clock,
    jscompat::{number_string, string, truthy},
    Error, Result,
};
use rusqlite::{
    params, params_from_iter,
    types::{Value as SqlValue, ValueRef},
    Connection, Transaction, TransactionBehavior,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
mod read;

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

pub struct Ledger {
    pub db: Connection,
    pub clock: Clock,
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

impl Ledger {
    pub fn open(path: &Path, clock: Clock) -> Result<Self> {
        if path != Path::new(":memory:") {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")?;
        let current: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if current > 5 {
            return Err(Error(format!(
                "账本结构版本 {current} 高于本程序支持的 5，拒绝以旧版本写入"
            )));
        }
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
        }
        Ok(Self { db, clock })
    }

    fn supersede(&self, record: &Value, id: i64, stats: &mut Value) -> Result<()> {
        if let Some(replaces) = record["replaces"].as_array() {
            for key in replaces {
                if key.as_str().is_some_and(|k| !k.is_empty()) && *key != record["record_key"] {
                    let count = self.db.execute("UPDATE usage_records SET active=0,superseded_by=? WHERE record_key=? AND active=1", params![id, key.as_str()])?;
                    if count > 0 {
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
        self.batch_cancellable(records, file, revision, elsewhere, price, || false)
    }

    pub fn batch_cancellable(
        &self,
        records: &[Value],
        file: Option<&str>,
        revision: Option<i64>,
        elsewhere: &[String],
        price: impl Fn(&Value) -> Value,
        cancelled: impl Fn() -> bool,
    ) -> Result<Value> {
        let transaction = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
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
            let old = rows(
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
                        .execute("UPDATE usage_records SET active=1 WHERE id=?", [id])?;
                    increment(&mut stats["counts"], "reactivated");
                }
                if old["content_hash"] == hash {
                    if !record["project_key"].is_null()
                        && record["project_key"] != old["project_key"]
                    {
                        self.db.execute(
                            "UPDATE usage_records SET project_key=? WHERE id=?",
                            params![sql_value(&record["project_key"]), id],
                        )?;
                        increment(&mut stats["counts"], "relabeled");
                    } else {
                        increment(&mut stats, "unchanged");
                    }
                    if file.is_some_and(|f| old["source_file"] != f)
                        || revision.is_some_and(|v| old["parser_rev"] != v)
                    {
                        self.db.execute("UPDATE usage_records SET source_file=coalesce(?,source_file),parser_rev=coalesce(?,parser_rev) WHERE id=?", params![file,revision,id])?;
                    }
                    self.supersede(record, id, &mut stats)?;
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
                let assignments = FIELDS.map(|f| format!("{f}=?")).join(",");
                self.db.execute(&format!("UPDATE usage_records SET content_hash=?,{assignments},revision=revision+1,price_version=?,cost_micros=?,price_source=? WHERE id=?"), params_from_iter(args.iter().map(sql_value)))?;
                increment(&mut stats, "updated");
                self.supersede(record, id, &mut stats)?;
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
                let placeholders = vec!["?"; args.len()].join(",");
                self.db.execute(&format!("INSERT INTO usage_records(record_key,content_hash,source,{},price_version,cost_micros,price_source) VALUES ({placeholders})", FIELDS.join(",")), params_from_iter(args.iter().map(sql_value)))?;
                increment(&mut stats, "inserted");
                self.supersede(record, self.db.last_insert_rowid(), &mut stats)?;
            }
        }
        if let Some(file) = file.filter(|_| !produced.is_empty() || !elsewhere.is_empty()) {
            let mut vanished = 0;
            for row in rows(&self.db, "SELECT id,record_key,parser_rev FROM usage_records WHERE source_file=? AND active=1", &[json!(file)])? {
                let key = row["record_key"].as_str().unwrap();
                if produced.contains(key) || elsewhere.iter().any(|s| s == key) { continue; }
                if revision.is_some_and(|r| r != row["parser_rev"].as_i64().unwrap_or(1)) {
                    self.db.execute("UPDATE usage_records SET active=0 WHERE id=?", [row["id"].as_i64().unwrap()])?;
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
        transaction.commit()?;
        Ok(stats)
    }

    pub fn begin_run(&self) -> Result<i64> {
        self.db.execute(
            "UPDATE ingest_runs SET status='abandoned' WHERE status='running'",
            [],
        )?;
        self.db.execute(
            "INSERT INTO ingest_runs(started_at,status) VALUES (?,'running')",
            [self.clock.millis() / 1000],
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
                    .filter_map(|key| counts.get(*key).map(|value| format!("\"{key}\":{value}")))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        });
        self.db.execute("UPDATE ingest_runs SET finished_at=?,status=?,attempted=?,inserted=?,updated=?,unchanged=?,rejected=?,notes=?,counts=? WHERE id=?", params![self.clock.millis()/1000,status,sql_value(&stats["attempted"]),sql_value(&stats["inserted"]),sql_value(&stats["updated"]),sql_value(&stats["unchanged"]),sql_value(&stats["rejected"]),notes,counts,id])?;
        Ok(())
    }

    pub fn fail_run(&self, id: i64, message: &str) -> Result<()> {
        self.db.execute(
            "UPDATE ingest_runs SET finished_at=?,status='failed',notes=? WHERE id=?",
            params![
                self.clock.millis() / 1000,
                json!([format!("run_failed: {message}")]).to_string(),
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
    fn writer_and_migrations_match_node() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../test/fixtures/parity/ledger.json"
        ))
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
                1 => include_str!("../../../../../test/fixtures/parity/v1.sql"),
                2 => include_str!("../../../../../test/fixtures/parity/v2.sql"),
                3 => include_str!("../../../../../test/fixtures/parity/v3.sql"),
                _ => include_str!("../../../../../test/fixtures/parity/v4.sql"),
            };
            initial.execute_batch(sql).unwrap();
            drop(initial);
            let migrated = Ledger::open(&path, Clock::Fixed(1768478400000)).unwrap();
            let schema = rows(&migrated.db,"SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name",&[]).unwrap();
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
            .execute_batch("PRAGMA user_version=6")
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
            Some(1),
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
