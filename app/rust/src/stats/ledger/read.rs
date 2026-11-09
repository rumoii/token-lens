use super::{rows, Ledger};
use crate::stats::{Error, Result};
use chrono::{Duration, NaiveDate};
use serde_json::{json, Value};
use std::collections::HashMap;

#[derive(Default)]
pub(super) struct PruneCache {
    version: Option<i64>,
    ranges: HashMap<(Option<String>, Option<String>), bool>,
    #[cfg(test)]
    estimates: usize,
}

const SUMS:&str="count(*) AS record_count,sum(input_tokens) AS input_tokens,sum(output_tokens) AS output_tokens,sum(cache_read_tokens) AS cache_read_tokens,sum(cache_write_tokens) AS cache_write_tokens,sum(cost_micros IS NULL) AS unpriced_records,sum(cost_micros) AS cost_micros";

fn dimension(name: &str) -> Result<&'static str> {
    match name {
        "source" => Ok("source"),
        "model" => Ok("model"),
        "project" => Ok("project_key"),
        _ => Err(Error(format!("未知的 breakdown 维度：{name}"))),
    }
}

fn scope(ledger: &Ledger, filter: &Value) -> Result<(String, Vec<Value>)> {
    let offset = filter["offsetMinutes"].as_i64().unwrap_or(0);
    let date = if offset == 0 {
        "date(observed_at)".into()
    } else {
        format!("date(observed_at,'{offset:+} minutes')")
    };
    let mut clauses = vec!["+active=1".to_owned()];
    let mut args = Vec::new();
    let mut boundaries = Vec::new();
    for (name, comparison, extra) in [("from", ">=", -1), ("to", "<", 2)] {
        if let Some(day) = filter[name].as_str().filter(|s| s.len() == 10) {
            if day.bytes().enumerate().all(|(i, c)| {
                if i == 4 || i == 7 {
                    c == b'-'
                } else {
                    c.is_ascii_digit()
                }
            }) {
                if let Ok(date) = NaiveDate::parse_from_str(day, "%Y-%m-%d") {
                    if date.format("%Y-%m-%d").to_string() != day {
                        continue;
                    }
                    if let Some(boundary) = date
                        .and_hms_opt(0, 0, 0)
                        .unwrap()
                        .checked_add_signed(Duration::minutes(extra * 1440 - offset))
                    {
                        boundaries.push((
                            comparison,
                            boundary
                                .and_utc()
                                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                        ));
                    }
                }
            }
        }
    }
    if !boundaries.is_empty() {
        let from = boundaries
            .iter()
            .find(|(op, _)| *op == ">=")
            .map(|(_, value)| value.clone());
        let to = boundaries
            .iter()
            .find(|(op, _)| *op == "<")
            .map(|(_, value)| value.clone());
        let indexed = ledger.use_observed_index(from, to)?;
        for (comparison, boundary) in boundaries {
            clauses.push(format!(
                "{}observed_at {comparison} ?",
                if indexed { "" } else { "+" }
            ));
            args.push(json!(boundary));
        }
    }
    for (name, column, comparison) in [
        ("from", date.as_str(), ">="),
        ("to", date.as_str(), "<="),
        ("source", "source", "="),
        ("model", "model", "="),
        ("project", "project_key", "="),
        ("session", "session_id", "="),
    ] {
        if let Some(value) = filter[name].as_str().filter(|s| !s.is_empty()) {
            clauses.push(format!("{column} {comparison} ?"));
            args.push(json!(value));
        }
    }
    Ok((clauses.join(" AND "), args))
}

impl Ledger {
    pub fn data_version(&self) -> Result<i64> {
        Ok(self
            .db
            .query_row("PRAGMA data_version", [], |row| row.get(0))?)
    }

    fn use_observed_index(&self, from: Option<String>, to: Option<String>) -> Result<bool> {
        let version = self.data_version()?;
        let mut cache = self.prune_cache.borrow_mut();
        if cache.version != Some(version) {
            cache.ranges.clear();
            cache.version = Some(version);
        }
        let key = (from, to);
        if let Some(indexed) = cache.ranges.get(&key) {
            return Ok(*indexed);
        }
        let mut clauses = Vec::new();
        let mut args = Vec::new();
        for (boundary, comparison) in [(&key.0, ">="), (&key.1, "<")] {
            if let Some(value) = boundary {
                clauses.push(format!("observed_at {comparison} ?"));
                args.push(json!(value));
            }
        }
        let range = rows(
            &self.db,
            &format!(
                "SELECT count(*) AS count FROM usage_records WHERE {}",
                clauses.join(" AND ")
            ),
            &args,
        )?[0]["count"]
            .as_i64()
            .unwrap();
        let total: i64 = self
            .db
            .query_row("SELECT count(*) FROM usage_records", [], |row| row.get(0))?;
        let indexed = range as f64 <= total as f64 * 0.25;
        cache.ranges.insert(key, indexed);
        #[cfg(test)]
        {
            cache.estimates += 1;
        }
        Ok(indexed)
    }
}

fn shape(mut row: Value) -> Value {
    let count = row["record_count"].as_i64().unwrap_or(0);
    let gross = [
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    ]
    .iter()
    .map(|f| row[*f].as_i64().unwrap_or(0))
    .sum::<i64>();
    row["gross_tokens"] = json!(gross);
    if count == 0 {
        for name in [
            "gross_tokens",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "cost_micros",
            "unpriced_records",
        ] {
            row[name] = json!(0);
        }
    }
    row
}

fn bucket_expr(granularity: &str, offset: i64, column: &str) -> Result<String> {
    let extra = if offset == 0 {
        String::new()
    } else {
        format!(",'{offset:+} minutes'")
    };
    match granularity {
        "day" => Ok(format!("date({column}{extra})")),
        "month" => Ok(format!("strftime('%Y-%m',{column}{extra})")),
        "hour" => Ok(format!("strftime('%Y-%m-%dT%H:00:00',{column}{extra})")),
        _ => Err(Error(format!("未知的时间粒度：{granularity}"))),
    }
}

impl Ledger {
    pub fn timeseries(&self, granularity: &str, filter: &Value) -> Result<Value> {
        self.time_buckets(granularity, None, filter)
    }

    pub fn timeseries_grouped(&self, granularity: &str, by: &str, filter: &Value) -> Result<Value> {
        self.time_buckets(granularity, Some(by), filter)
    }

    fn time_buckets(&self, granularity: &str, by: Option<&str>, filter: &Value) -> Result<Value> {
        let offset = filter["offsetMinutes"].as_i64().unwrap_or(0);
        let expr = bucket_expr(granularity, offset, "observed_at")?;
        let end = bucket_expr(granularity, offset, "ended_at")?;
        let column = by
            .map(|name| match name {
                "model" => Ok("model"),
                "source" => Ok("source"),
                "project" => Ok("project_key"),
                _ => Err(Error(format!("未知的分组维度：{name}"))),
            })
            .transpose()?;
        // Preserve SQL NULL for malformed ended_at (D33 addendum 1).
        let same = format!("(ended_at IS NOT NULL AND {expr} = {end})");
        let (clause, args) = scope(self, filter)?;
        let (group_select, group_by) = column
            .map_or((String::new(), "bucket".to_owned()), |column| {
                (format!(",{column} AS grp"), "bucket,grp".into())
            });
        let mut points = rows(&self.db, &format!("SELECT {expr} AS bucket{group_select},{SUMS} FROM usage_records WHERE {clause} AND (kind='event' OR (kind='cumulative' AND {same})) GROUP BY {group_by} ORDER BY bucket ASC"), &args)?;
        for row in &mut points {
            if let Some(group) = row.as_object_mut().unwrap().remove("grp") {
                row["group"] = group;
            }
            *row = shape(row.clone());
        }
        let raw = rows(&self.db, &format!("SELECT {SUMS} FROM usage_records WHERE {clause} AND (kind='cumulative' AND NOT {same})"), &args)?.remove(0);
        let unallocated = if raw["record_count"].as_i64().unwrap_or(0) > 0 {
            let mut value = shape(raw);
            value["reason"] = json!("cumulative_without_time_distribution");
            value
        } else {
            Value::Null
        };
        Ok(if by.is_some() {
            json!({"rows":points,"unallocated":unallocated})
        } else {
            json!({"points":points,"unallocated":unallocated})
        })
    }

    // Cursor encoding belongs to jscompat/service; this query takes the decoded offset.
    pub fn sessions(
        &self,
        limit: Option<i64>,
        offset: u64,
        filter: &Value,
    ) -> Result<(Vec<Value>, Option<u64>)> {
        let limit = limit.filter(|n| *n != 0).unwrap_or(50).clamp(1, 200);
        let (clause, mut args) = scope(self, filter)?;
        args.extend([json!(limit + 1), json!(offset)]);
        let mut items = rows(&self.db, &format!("SELECT source,session_id,max(project_key) AS project_key,count(DISTINCT project_key) AS project_key_variants,min(observed_at) AS started_at,max(coalesce(ended_at,observed_at)) AS last_seen_at,{SUMS} FROM usage_records WHERE {clause} AND session_id IS NOT NULL GROUP BY source,session_id ORDER BY last_seen_at DESC,session_id ASC LIMIT ? OFFSET ?"), &args)?;
        let next = (items.len() > limit as usize).then(|| offset + limit as u64);
        items.truncate(limit as usize);
        for row in &mut items {
            if row["project_key_variants"] != 1 {
                row["project_key"] = Value::Null;
            }
            row.as_object_mut().unwrap().remove("project_key_variants");
            *row = shape(row.clone());
        }
        Ok((items, next))
    }

    pub fn session_detail(
        &self,
        source: &str,
        session: &str,
        granularity: &str,
        offset: i32,
    ) -> Result<Option<Value>> {
        if source.is_empty() || session.is_empty() {
            return Err(Error("会话详情必须同时给出 source 与 session_id".into()));
        }
        let expr = bucket_expr(granularity, i64::from(offset), "observed_at")?;
        let (clause, args) = scope(
            self,
            &json!({"source":source,"session":session,"offsetMinutes":offset}),
        )?;
        let row = rows(&self.db, &format!("SELECT min(observed_at) AS started_at,max(coalesce(ended_at,observed_at)) AS last_seen_at,{SUMS},max(project_key) AS project_key,count(DISTINCT project_key) AS project_variants,sum(CASE WHEN kind='event' THEN 1 ELSE 0 END) AS event_records,sum(CASE WHEN kind='cumulative' THEN 1 ELSE 0 END) AS cumulative_records FROM usage_records WHERE {clause}"), &args)?.remove(0);
        if row["record_count"] == 0 {
            return Ok(None);
        }
        let mut summary = shape(row.clone());
        summary["source"] = json!(source);
        summary["session_id"] = json!(session);
        if row["project_variants"] != 1 {
            summary["project_key"] = Value::Null;
        }
        for key in ["project_variants", "event_records", "cumulative_records"] {
            summary.as_object_mut().unwrap().remove(key);
        }
        let models: Vec<_> = rows(&self.db, &format!("SELECT model,{SUMS} FROM usage_records WHERE {clause} GROUP BY model ORDER BY record_count DESC"), &args)?.into_iter().map(shape).collect();
        let timeline: Vec<_> = rows(&self.db, &format!("SELECT {expr} AS bucket,{SUMS} FROM usage_records WHERE {clause} AND kind='event' GROUP BY bucket ORDER BY bucket ASC"), &args)?.into_iter().map(shape).collect();
        Ok(Some(
            json!({"summary":summary,"models":models,"timeline":timeline,"kinds":{"event":row["event_records"],"cumulative":row["cumulative_records"]}}),
        ))
    }

    pub fn source_status(&self) -> Result<Vec<Value>> {
        rows(&self.db,"SELECT source,count(*) AS records,sum(CASE WHEN kind='cumulative' THEN 1 ELSE 0 END) AS cumulative_records,min(observed_at) AS first_observed_at,max(coalesce(ended_at,observed_at)) AS last_observed_at FROM usage_records WHERE active=1 GROUP BY source ORDER BY source ASC", &[])
    }

    pub fn source_checks(&self, now: &str) -> Result<Value> {
        let mut checks = json!({});
        for mut row in rows(&self.db,"SELECT source,sum(CASE WHEN observed_at > ? OR ended_at > ? OR observed_at < '2023-01-01' THEN 1 ELSE 0 END) AS time_out_of_range,sum(CASE WHEN kind='event' AND coalesce(input_tokens,0)+coalesce(output_tokens,0)+coalesce(cache_read_tokens,0)+coalesce(cache_write_tokens,0)>100000000 THEN 1 ELSE 0 END) AS huge_requests,sum(CASE WHEN model IS NULL THEN 1 ELSE 0 END) AS null_model FROM usage_records WHERE active=1 GROUP BY source", &[json!(now),json!(now)])? {
            let source = row.as_object_mut().unwrap().remove("source").unwrap();
            row["mixed_kind_sessions"] = json!(0);
            checks[source.as_str().unwrap()] = row;
        }
        for row in rows(&self.db,"SELECT source,count(*) AS sessions FROM (SELECT source,session_id FROM usage_records WHERE active=1 AND session_id IS NOT NULL GROUP BY source,session_id HAVING count(DISTINCT kind)>1) GROUP BY source", &[])? {
            checks[row["source"].as_str().unwrap()]["mixed_kind_sessions"] = row["sessions"].clone();
        }
        Ok(checks)
    }

    pub fn source_files(&self) -> Result<Vec<Value>> {
        rows(&self.db,"SELECT source,source_file,count(*) AS records FROM usage_records WHERE active=1 GROUP BY source,source_file", &[])
    }

    pub fn model_price_marks(&self) -> Result<Vec<Value>> {
        rows(&self.db,"SELECT model,provider,CASE WHEN instr(price_source,';')>0 THEN substr(price_source,instr(price_source,';')+1) ELSE '' END AS mark,count(*) AS records,sum(count(*)) OVER (PARTITION BY model) AS model_records FROM usage_records WHERE active=1 GROUP BY model,mark,provider ORDER BY model_records DESC,model,mark,provider", &[])
    }

    #[allow(
        dead_code,
        reason = "Ledger-only reconciliation query; intentionally absent from FFI"
    )]
    pub fn legacy_count(&self) -> Result<i64> {
        Ok(self
            .db
            .query_row("SELECT count(*) FROM legacy_records", [], |row| row.get(0))?)
    }
}

impl Ledger {
    pub fn totals(&self, filter: &Value) -> Result<Value> {
        let (clause, args) = scope(self, filter)?;
        let mut row=shape(rows(&self.db,&format!("SELECT {SUMS},sum(input_tokens IS NULL) AS input_unknown,sum(output_tokens IS NULL) AS output_unknown,sum(cache_read_tokens IS NULL) AS cache_read_unknown,sum(cache_write_tokens IS NULL) AS cache_write_unknown FROM usage_records WHERE {clause}"),&args)?.remove(0));
        for name in [
            "input_unknown",
            "output_unknown",
            "cache_read_unknown",
            "cache_write_unknown",
        ] {
            if row[name].is_null() {
                row[name] = json!(0);
            }
        }
        Ok(row)
    }
    pub fn breakdown(&self, by: &str, filter: &Value) -> Result<Vec<Value>> {
        let column = dimension(by)?;
        let (clause, args) = scope(self, filter)?;
        Ok(rows(&self.db,&format!("SELECT {column} AS bucket,{SUMS} FROM usage_records WHERE {clause} GROUP BY {column} ORDER BY cost_micros DESC,record_count DESC"),&args)?.into_iter().map(shape).collect())
    }
    pub fn grouped(&self, outer: &str, inner: &str, filter: &Value) -> Result<Vec<Value>> {
        let a = dimension(outer)?;
        let b = dimension(inner)?;
        let (clause, args) = scope(self, filter)?;
        Ok(rows(&self.db,&format!("SELECT {a} AS outer_key,{b} AS inner_key,{SUMS} FROM usage_records WHERE {clause} GROUP BY outer_key,inner_key ORDER BY cost_micros DESC"),&args)?.into_iter().map(shape).collect())
    }
    pub fn activity(&self, filter: &Value) -> Result<Value> {
        let (clause, args) = scope(self, filter)?;
        let mut row=rows(&self.db,&format!("SELECT count(DISTINCT session_id) AS sessions,sum(kind='event') AS turns,sum(coalesce(input_tokens,0)) AS input_tokens,sum(coalesce(cache_read_tokens,0)) AS cache_read_tokens,min(observed_at) AS first_seen,max(coalesce(ended_at,observed_at)) AS last_seen FROM usage_records WHERE {clause}"),&args)?.remove(0);
        for name in ["sessions", "turns", "input_tokens", "cache_read_tokens"] {
            if row[name].is_null() {
                row[name] = json!(0);
            }
        }
        Ok(row)
    }
    pub fn cost_rows(&self, filter: &Value) -> Result<Vec<Value>> {
        let (clause, args) = scope(self, filter)?;
        rows(&self.db,&format!("SELECT source,model,provider,project_key,price_version,cost_micros,kind,observed_at,ended_at,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,cache_write_5m_tokens,cache_write_1h_tokens FROM usage_records WHERE {clause} AND cost_micros IS NOT NULL"),&args)
    }
    pub fn last_run(&self) -> Result<Value> {
        let Some(mut row)=rows(&self.db,"SELECT id,status,started_at,finished_at,attempted,inserted,updated,unchanged,rejected,notes,counts FROM ingest_runs ORDER BY id DESC LIMIT 1",&[])?.pop() else{return Ok(Value::Null)};
        let notes = row["notes"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|text| {
                serde_json::from_str::<Value>(text)
                    .ok()
                    .filter(Value::is_array)
                    .map(|value| {
                        json!(value
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(crate::stats::jscompat::string)
                            .collect::<Vec<_>>())
                    })
                    .unwrap_or_else(|| json!([text]))
            })
            .unwrap_or(json!([]));
        row.as_object_mut().unwrap().remove("notes");
        row["anomalies"] = notes;
        if !crate::stats::jscompat::truthy(&row["status"]) {
            row["status"] = json!("unknown");
        }
        row["counts"] = row["counts"]
            .as_str()
            .and_then(|text| serde_json::from_str::<Value>(text).ok())
            .filter(Value::is_object)
            .unwrap_or(Value::Null);
        Ok(row)
    }
}

#[cfg(test)]
mod d33_tests {
    use super::*;
    use crate::stats::{clock::Clock, pricing};
    use std::path::Path;

    #[test]
    fn d33_prune_plans_cache_and_external_version() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ledger.db");
        let ledger = Ledger::open(&path, Clock::Fixed(1768478400000)).unwrap();
        let records: Vec<_> = (0..40).map(|i| json!({"record_key":format!("r{i}"),"source":"s","observed_at":format!("2026-01-{:02}T00:00:00.000Z",i%28+1),"input_tokens":i})).collect();
        ledger
            .batch(&records, None, None, &[], pricing::cost_of)
            .unwrap();
        for (filter, indexed) in [
            (json!({"from":"2026-01-10","to":"2026-01-10"}), true),
            (json!({"from":"2026-01-01","to":"2026-01-28"}), false),
        ] {
            let (clause, args) = scope(&ledger, &filter).unwrap();
            let plan = rows(
                &ledger.db,
                &format!("EXPLAIN QUERY PLAN SELECT {SUMS} FROM usage_records WHERE {clause}"),
                &args,
            )
            .unwrap();
            assert_eq!(
                plan.iter()
                    .any(|r| r["detail"].as_str().unwrap().contains("idx_usage_observed")),
                indexed
            );
            let observed = rows(
                &ledger.db,
                &format!(
                    "SELECT {SUMS} FROM usage_records WHERE {}",
                    clause.replace("+observed_at", "observed_at")
                ),
                &args,
            )
            .unwrap();
            let scan = rows(
                &ledger.db,
                &format!(
                    "SELECT {SUMS} FROM usage_records WHERE {}",
                    clause
                        .replace("+observed_at", "observed_at")
                        .replace("observed_at >=", "+observed_at >=")
                        .replace("observed_at <", "+observed_at <")
                ),
                &args,
            )
            .unwrap();
            assert_eq!(observed, scan);
        }
        let filter = json!({"from":"2026-01-10","to":"2026-01-10"});
        let estimates = ledger.prune_cache.borrow().estimates;
        ledger.totals(&filter).unwrap();
        ledger.timeseries("day", &filter).unwrap();
        assert_eq!(ledger.prune_cache.borrow().estimates, estimates);
        let writer = rusqlite::Connection::open(&path).unwrap();
        let version = ledger.data_version().unwrap();
        writer
            .execute("UPDATE usage_records SET input_tokens=input_tokens+1", [])
            .unwrap();
        assert_ne!(ledger.data_version().unwrap(), version);
        ledger.totals(&filter).unwrap();
        assert_eq!(ledger.prune_cache.borrow().estimates, estimates + 1);
        assert_eq!(ledger.prune_cache.borrow().ranges.len(), 1);
        let (clause, args) =
            scope(&ledger, &json!({"from":"2026-1-010","to":"2026-02-30"})).unwrap();
        assert!(!clause.contains("observed_at >="));
        assert!(!clause.contains("observed_at < ?"));
        assert_eq!(args.len(), 2);
    }

    #[test]
    fn d33_read_queries_partition_and_preserve_unknowns() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        ledger.batch(&[
            json!({"record_key":"event","source":"s","session_id":"mixed","project_key":"a","model":null,"observed_at":"2026-01-15T00:00:00.000Z","input_tokens":100}),
            json!({"record_key":"snapshot","source":"s","session_id":"mixed","project_key":"b","kind":"cumulative","observed_at":"2026-01-15T00:10:00.000Z","ended_at":"2026-01-15T01:10:00.000Z","input_tokens":200}),
            json!({"record_key":"unknown","source":"s","kind":"cumulative","observed_at":"2026-01-15T02:00:00.000Z"})
        ], None, None, &[], pricing::cost_of).unwrap();
        let hour = ledger.timeseries("hour", &json!({})).unwrap();
        assert_eq!(hour["points"][0]["input_tokens"], 100);
        assert_eq!(hour["points"][0]["output_tokens"], Value::Null);
        assert_eq!(hour["unallocated"]["record_count"], 2);
        assert_eq!(hour["unallocated"]["input_tokens"], 200);
        assert_eq!(
            ledger.timeseries("day", &json!({})).unwrap()["points"][0]["input_tokens"],
            300
        );
        assert_eq!(
            ledger
                .timeseries_grouped("hour", "model", &json!({}))
                .unwrap()["rows"][0]["group"],
            Value::Null
        );
        let detail = ledger
            .session_detail("s", "mixed", "hour", 0)
            .unwrap()
            .unwrap();
        assert_eq!(detail["summary"]["project_key"], Value::Null);
        assert_eq!(detail["timeline"].as_array().unwrap().len(), 1);
        assert_eq!(detail["kinds"], json!({"event":1,"cumulative":1}));
        assert!(ledger
            .session_detail("s", "missing", "hour", 0)
            .unwrap()
            .is_none());
        let (items, next) = ledger.sessions(Some(0), 0, &json!({})).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["project_key"], Value::Null);
        assert_eq!(next, None);
        assert_eq!(ledger.source_status().unwrap()[0]["records"], 3);
        assert_eq!(
            ledger.source_checks("2026-01-15T12:00:00.000Z").unwrap()["s"]["mixed_kind_sessions"],
            1
        );
        assert_eq!(ledger.source_files().unwrap()[0]["records"], 3);
        assert_eq!(ledger.model_price_marks().unwrap()[0]["model_records"], 3);
        assert_eq!(ledger.legacy_count().unwrap(), 0);
        assert!(ledger.timeseries("week", &json!({})).is_err());
        assert!(ledger
            .timeseries_grouped("day", "invalid", &json!({}))
            .is_err());
    }
}
