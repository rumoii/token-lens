use super::{rows, Ledger};
use crate::stats::{Error, Result};
use chrono::{Duration, NaiveDate};
use serde_json::{json, Value};

const SUMS:&str="count(*) AS record_count,sum(input_tokens) AS input_tokens,sum(output_tokens) AS output_tokens,sum(cache_read_tokens) AS cache_read_tokens,sum(cache_write_tokens) AS cache_write_tokens,sum(cost_micros IS NULL) AS unpriced_records,sum(cost_micros) AS cost_micros";

fn dimension(name: &str) -> Result<&'static str> {
    match name {
        "source" => Ok("source"),
        "model" => Ok("model"),
        "project" => Ok("project_key"),
        _ => Err(Error(format!("未知的 breakdown 维度：{name}"))),
    }
}

fn scope(filter: &Value) -> (String, Vec<Value>) {
    let offset = filter["offsetMinutes"].as_i64().unwrap_or(0);
    let date = if offset == 0 {
        "date(observed_at)".into()
    } else {
        format!("date(observed_at,'{offset:+} minutes')")
    };
    let mut clauses = vec!["+active=1".to_owned()];
    let mut args = Vec::new();
    for (name, comparison, extra) in [("from", ">=", -1), ("to", "<", 2)] {
        if let Some(day) = filter[name].as_str().filter(|s| s.len() == 10) {
            if let Ok(date) = NaiveDate::parse_from_str(day, "%Y-%m-%d") {
                if let Some(boundary) = date
                    .and_hms_opt(0, 0, 0)
                    .unwrap()
                    .checked_add_signed(Duration::minutes(extra * 1440 - offset))
                {
                    clauses.push(format!("observed_at {comparison} ?"));
                    args.push(json!(boundary
                        .and_utc()
                        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)));
                }
            }
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
    (clauses.join(" AND "), args)
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

impl Ledger {
    pub fn totals(&self, filter: &Value) -> Result<Value> {
        let (clause, args) = scope(filter);
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
        let (clause, args) = scope(filter);
        Ok(rows(&self.db,&format!("SELECT {column} AS bucket,{SUMS} FROM usage_records WHERE {clause} GROUP BY {column} ORDER BY cost_micros DESC,record_count DESC"),&args)?.into_iter().map(shape).collect())
    }
    pub fn grouped(&self, outer: &str, inner: &str, filter: &Value) -> Result<Vec<Value>> {
        let a = dimension(outer)?;
        let b = dimension(inner)?;
        let (clause, args) = scope(filter);
        Ok(rows(&self.db,&format!("SELECT {a} AS outer_key,{b} AS inner_key,{SUMS} FROM usage_records WHERE {clause} GROUP BY outer_key,inner_key ORDER BY cost_micros DESC"),&args)?.into_iter().map(shape).collect())
    }
    pub fn activity(&self, filter: &Value) -> Result<Value> {
        let (clause, args) = scope(filter);
        let mut row=rows(&self.db,&format!("SELECT count(DISTINCT session_id) AS sessions,sum(kind='event') AS turns,sum(coalesce(input_tokens,0)) AS input_tokens,sum(coalesce(cache_read_tokens,0)) AS cache_read_tokens,min(observed_at) AS first_seen,max(coalesce(ended_at,observed_at)) AS last_seen FROM usage_records WHERE {clause}"),&args)?.remove(0);
        for name in ["sessions", "turns", "input_tokens", "cache_read_tokens"] {
            if row[name].is_null() {
                row[name] = json!(0);
            }
        }
        Ok(row)
    }
    pub fn cost_rows(&self, filter: &Value) -> Result<Vec<Value>> {
        let (clause, args) = scope(filter);
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
                    .unwrap_or_else(|| json!([text]))
            })
            .unwrap_or(json!([]));
        row.as_object_mut().unwrap().remove("notes");
        row["anomalies"] = notes;
        row["counts"] = row["counts"]
            .as_str()
            .and_then(|text| serde_json::from_str::<Value>(text).ok())
            .filter(Value::is_object)
            .unwrap_or(Value::Null);
        Ok(row)
    }
}
