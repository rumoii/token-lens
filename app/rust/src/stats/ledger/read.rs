use super::{rows, Ledger};
use crate::stats::{Error, Result};
use chrono::{Duration, NaiveDate};
use serde_json::{json, Value};
use std::collections::HashMap;

#[cfg(test)]
#[path = "requests_tests.rs"]
mod requests_tests;

#[derive(Default)]
pub(super) struct PruneCache {
    version: Option<i64>,
    ranges: HashMap<(Option<String>, Option<String>), bool>,
    #[cfg(test)]
    estimates: usize,
}

const SUMS:&str="count(*) AS record_count,sum(input_tokens) AS input_tokens,sum(output_tokens) AS output_tokens,sum(cache_read_tokens) AS cache_read_tokens,sum(cache_write_tokens) AS cache_write_tokens,sum(cost_micros IS NULL) AS unpriced_records,sum(cost_micros) AS cost_micros";

const REQUESTS: &str = "nullif(sum(kind='event'),0) AS request_count";
const SESSION_COUNT: &str =
    "count(DISTINCT CASE WHEN session_id IS NOT NULL THEN json_array(source,session_id) END) AS session_count";

const EVENT_GROSS: &str = "coalesce(sum(CASE WHEN kind='event' THEN input_tokens END),0)+coalesce(sum(CASE WHEN kind='event' THEN output_tokens END),0)+coalesce(sum(CASE WHEN kind='event' THEN cache_read_tokens END),0)+coalesce(sum(CASE WHEN kind='event' THEN cache_write_tokens END),0) AS event_gross_tokens";

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
    if filter["projectPaths"].is_array() {
        clauses.push("project_key IN (SELECT value FROM json_each(?))".into());
        args.push(json!(filter["projectPaths"].to_string()));
    }
    Ok((clauses.join(" AND "), args))
}

fn summarize_timing(records: &[Value]) -> Value {
    let requests: Vec<_> = records
        .iter()
        .filter(|r| r["source"] != "grok" && r["scope"] != "turn")
        .cloned()
        .collect();
    let turns: Vec<_> = records
        .iter()
        .filter(|r| r["source"] == "grok" || r["scope"] == "turn")
        .cloned()
        .collect();
    let mut result = summarize_scope(&requests);
    let mut turn = summarize_scope(&turns);
    turn["turn_count"] = turn
        .as_object_mut()
        .unwrap()
        .remove("request_count")
        .unwrap();
    result["turn"] = turn;
    result
}
fn summarize_scope(records: &[Value]) -> Value {
    let mut ttft = std::collections::BTreeMap::<String, Vec<i64>>::new();
    let mut speed = std::collections::BTreeMap::<String, (i64, i64, i64)>::new();
    let mut throughput = std::collections::BTreeMap::<String, (i64, i64, i64)>::new();
    for r in records {
        if let (Some(method), Some(ms)) = (
            r["ttft_method"].as_str(),
            r["ttft_ms"].as_i64().filter(|n| *n >= 0),
        ) {
            ttft.entry(method.into()).or_default().push(ms);
        }
        if r["status"] != "completed" {
            continue;
        }
        for (groups, field, method_field) in [
            (&mut speed, "generation_ms", "generation_method"),
            (&mut throughput, "duration_ms", "duration_method"),
        ] {
            if let (Some(method), Some(ms), Some(output)) = (
                r[method_field].as_str(),
                r[field].as_i64().filter(|n| *n > 0),
                r["timing_output_tokens"].as_i64().filter(|n| *n >= 0),
            ) {
                let group = groups.entry(method.into()).or_default();
                group.0 += output;
                group.1 += ms;
                group.2 += 1;
            }
        }
    }
    let ttft:Vec<_>=ttft.into_iter().map(|(method,mut values)| {
        values.sort_unstable();
        // Nearest rank: sorted[ceil(p*n)-1], including the lower median for even n.
        let percentile=|percent:usize|values[(values.len()*percent).div_ceil(100)-1];
        json!({"method":method,"sample_count":values.len(),"median_ms":percentile(50),"p90_ms":percentile(90)})
    }).collect();
    let speed:Vec<_>=speed.into_iter().map(|(method,(output,ms,n))|json!({"method":method,"sample_count":n,"output_tokens":output,"generation_ms":ms,"tokens_per_second":output as f64*1000.0/ms as f64})).collect();
    let throughput:Vec<_>=throughput.into_iter().map(|(method,(output,ms,n))|json!({"method":method,"sample_count":n,"output_tokens":output,"duration_ms":ms,"tokens_per_second":output as f64*1000.0/ms as f64})).collect();
    json!({"request_count":records.len(),"ttft":if ttft.is_empty(){Value::Null}else{json!(ttft)},"speed":if speed.is_empty(){Value::Null}else{json!(speed)},"throughput":if throughput.is_empty(){Value::Null}else{json!(throughput)}})
}

impl Ledger {
    pub(crate) fn output_projects(&self, filter: &Value) -> Result<Vec<String>> {
        let (clause, args) = scope(self, filter)?;
        Ok(rows(&self.db, &format!(
            "SELECT DISTINCT project_key FROM usage_records WHERE {clause} AND project_key IS NOT NULL"
        ), &args)?.into_iter().filter_map(|row| row["project_key"].as_str().map(str::to_owned)).collect())
    }

    pub(crate) fn output_totals(&self, filter: &Value) -> Result<Value> {
        let (clause, args) = scope(self, filter)?;
        Ok(shape(
            rows(
                &self.db,
                &format!(
                    "SELECT {SUMS},{REQUESTS},{SESSION_COUNT},min(observed_at) AS started_at,
            max(coalesce(ended_at,observed_at)) AS last_seen_at,
            CASE WHEN count(DISTINCT project_key)=1 THEN max(project_key) END AS project_key
            FROM usage_records WHERE {clause}"
                ),
                &args,
            )?
            .remove(0),
        ))
    }

    pub(crate) fn output_groups(&self, by: &str, filter: &Value) -> Result<Vec<Value>> {
        let (clause, args) = scope(self, filter)?;
        let column = match by {
            "tool" => "source".into(),
            "model" | "project" => dimension(by)?.into(),
            time => {
                let offset = filter["offsetMinutes"].as_i64().unwrap_or_default();
                let start = bucket_expr(time, offset, "observed_at")?;
                let end = bucket_expr(time, offset, "ended_at")?;
                // The app leaves cumulative usage spanning buckets unallocated.
                format!("CASE WHEN kind='event' OR {start}={end} THEN {start} END")
            }
        };
        Ok(rows(
            &self.db,
            &format!(
                "SELECT {column} AS bucket,{SUMS},{REQUESTS},{SESSION_COUNT}
            FROM usage_records WHERE {clause} GROUP BY bucket ORDER BY bucket IS NULL,bucket"
            ),
            &args,
        )?
        .into_iter()
        .map(shape)
        .collect())
    }

    pub(crate) fn output_sessions(
        &self,
        filter: &Value,
        sort: &str,
        limit: usize,
        after: Option<&[Value; 4]>,
    ) -> Result<Vec<Value>> {
        let (clause, mut args) = scope(self, filter)?;
        let (missing, rank) = match sort {
            "cost" => ("cost_micros IS NULL", "coalesce(cost_micros,0)"),
            "tokens" => ("0", "coalesce(input_tokens,0)+coalesce(output_tokens,0)+coalesce(cache_read_tokens,0)+coalesce(cache_write_tokens,0)"),
            _ => ("0", "last_seen_at"),
        };
        let seek = after.map_or("", |key| {
            args.extend(key.iter().cloned());
            // Cursor comparisons and ORDER BY use the same tuple and collation.
            // Only the rank is descending.
            "WHERE missing > cursor.m OR (missing=cursor.m AND (rank < cursor.r OR
                (rank=cursor.r AND (session_id,source) > (cursor.s,cursor.t))))"
        });
        let cursor = if after.is_some() {
            ", cursor AS (SELECT ? AS m,? AS r,? AS s,? AS t)"
        } else {
            ""
        };
        let join = if after.is_some() {
            "CROSS JOIN cursor"
        } else {
            ""
        };
        args.push(json!(limit + 1));
        Ok(rows(&self.db, &format!(
            "WITH scoped AS (
                SELECT source,session_id,{SUMS},{REQUESTS},min(observed_at) AS started_at,
                max(coalesce(ended_at,observed_at)) AS last_seen_at,
                CASE WHEN count(DISTINCT project_key)=1 THEN max(project_key) END AS project_key
                FROM usage_records WHERE {clause} AND session_id IS NOT NULL GROUP BY source,session_id
            ), ranked AS (SELECT *,{missing} AS missing,{rank} AS rank FROM scoped){cursor}
            SELECT ranked.* FROM ranked {join} {seek}
            ORDER BY missing,rank DESC,session_id,source LIMIT ?"
        ), &args)?.into_iter().map(shape).collect())
    }

    pub(crate) fn output_source_results(&self) -> Result<HashMap<String, Value>> {
        Ok(rows(
            &self.db,
            "SELECT source,result FROM (
                SELECT substr(key,13) AS source,value AS result,
                row_number() OVER (PARTITION BY key ORDER BY ingest_runs.id DESC) AS position
                FROM ingest_runs, json_each(CASE WHEN json_valid(counts) THEN counts END)
                WHERE key GLOB 'sync_source.*'
            ) WHERE position=1",
            &[],
        )?
        .into_iter()
        .map(|row| {
            (
                row["source"].as_str().unwrap().to_owned(),
                row["result"].clone(),
            )
        })
        .collect())
    }

    pub fn requests(
        &self,
        filter: &Value,
        timed_only: bool,
        sort: &str,
        descending: bool,
        limit: i64,
        offset: i64,
    ) -> Result<Value> {
        let order = match sort {
            "time" => "observed_at",
            "cost" => "cost_micros",
            "ttft" => "ttft_ms",
            "speed" => "coalesce(speed_tps,throughput_tps)",
            _ => return Err(Error("INVALID_PARAM: sort".into())),
        };
        if limit <= 0 || offset < 0 {
            return Err(Error("INVALID_PARAM: pagination".into()));
        }
        // Count, thresholds and page must observe the same committed ledger.
        let _snapshot = self.db.unchecked_transaction()?;
        let (mut clause, mut args) = scope(self, filter)?;
        if let Some(bucket) = filter["bucket"].as_str().filter(|s| !s.is_empty()) {
            let granularity = match bucket.len() {
                7 => "month",
                10 => "day",
                19 => "hour",
                _ => return Err(Error("INVALID_PARAM: bucket".into())),
            };
            let expr = bucket_expr(
                granularity,
                filter["offsetMinutes"].as_i64().unwrap_or(0),
                "observed_at",
            )?;
            clause.push_str(&format!(" AND {expr}=?"));
            args.push(json!(bucket));
        }
        let speed = "CASE WHEN t.status='completed' AND t.generation_ms>0 AND t.timing_output_tokens IS NOT NULL THEN t.timing_output_tokens*1000.0/t.generation_ms END";
        let throughput = "CASE WHEN t.status='completed' AND t.duration_ms>0 AND t.timing_output_tokens IS NOT NULL THEN t.timing_output_tokens*1000.0/t.duration_ms END";
        let scoped = format!("SELECT * FROM usage_records WHERE {clause} AND kind='event'");
        let projected = format!("SELECT u.record_key AS id,u.observed_at,u.source,u.session_id,u.project_key,u.model,u.input_tokens,u.output_tokens,u.cache_read_tokens,u.cache_write_tokens,u.cost_micros,u.price_version,u.price_source,(u.cost_micros IS NULL) AS unpriced_records,t.scope,t.status,t.ttft_ms,{speed} AS speed_tps,{throughput} AS throughput_tps FROM ({scoped}) u LEFT JOIN usage_timings t ON t.record_key=u.record_key");
        let timed = if timed_only {
            "WHERE ttft_ms IS NOT NULL OR speed_tps IS NOT NULL OR throughput_tps IS NOT NULL"
        } else {
            ""
        };
        let total_sql = if timed_only {
            format!("SELECT count(*) AS total FROM ({projected}) {timed}")
        } else {
            format!("SELECT count(*) AS total FROM ({scoped})")
        };
        let include_summary = filter["include_summary"].as_bool().unwrap_or(true);
        let total = if include_summary {
            rows(&self.db, &total_sql, &args)?.remove(0)["total"].clone()
        } else {
            Value::Null
        };
        // Materialize only the two percentile samples, never the full request list.
        // Counts exclude NULL independently; nearest rank uses ceil(p*n)-1.
        let slow = if include_summary {
            rows(&self.db, &format!("WITH samples AS MATERIALIZED (
            SELECT t.ttft_ms,{speed} AS speed_tps FROM usage_timings t
            JOIN ({scoped}) u ON u.record_key=t.record_key WHERE t.scope='request'
        ), counts AS (SELECT count(ttft_ms) AS nt,count(speed_tps) AS ns FROM samples)
        SELECT CASE WHEN nt>=10 THEN (SELECT ttft_ms FROM samples WHERE ttft_ms IS NOT NULL ORDER BY ttft_ms LIMIT 1 OFFSET (SELECT (nt*90+99)/100-1 FROM counts)) END AS ttft_ms,
        CASE WHEN ns>=10 THEN (SELECT speed_tps FROM samples WHERE speed_tps IS NOT NULL ORDER BY speed_tps LIMIT 1 OFFSET (SELECT (ns+9)/10-1 FROM counts)) END AS speed_tps FROM counts"), &args)?.remove(0)
        } else {
            Value::Null
        };
        args.extend([json!(limit), json!(offset)]);
        let direction = if descending { "DESC" } else { "ASC" };
        let items = rows(&self.db, &format!("SELECT * FROM ({projected}) {timed} ORDER BY {order} {direction} NULLS LAST,observed_at DESC,id ASC LIMIT ? OFFSET ?"), &args)?;
        Ok(json!({"items":items,"total":total,"slow":slow}))
    }
    fn timing_rows(&self, filter: &Value) -> Result<Vec<Value>> {
        let (clause, args) = scope(self, filter)?;
        rows(&self.db,&format!("SELECT u.source,u.model,u.project_key,t.scope,t.ttft_ms,t.ttft_method,t.generation_ms,t.generation_method,t.duration_ms,t.duration_method,t.timing_output_tokens,t.status FROM (SELECT record_key,source,model,project_key FROM usage_records WHERE {clause} AND kind='event') u LEFT JOIN usage_timings t ON t.record_key=u.record_key"),&args)
    }
    pub fn timing_summary(&self, filter: &Value) -> Result<Value> {
        Ok(summarize_timing(&self.timing_rows(filter)?))
    }
    pub fn timing_groups(&self, by: &str, filter: &Value) -> Result<HashMap<String, Value>> {
        if by != "source_model" {
            dimension(by)?;
        }
        let mut groups = HashMap::<String, Vec<Value>>::new();
        for row in self.timing_rows(filter)? {
            let key = if by == "source_model" {
                json!([row["source"], row["model"]]).to_string()
            } else {
                row[if by == "project" { "project_key" } else { by }].to_string()
            };
            groups.entry(key).or_default().push(row);
        }
        Ok(groups
            .into_iter()
            .map(|(key, rows)| (key, summarize_timing(&rows)))
            .collect())
    }
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

fn session_sql(clause: &str, order: &str) -> String {
    let lifetime_sums = SUMS.replace("sum(", "sum(u.");
    let lifetime_requests = REQUESTS.replace("kind", "u.kind");
    let lifetime_events = EVENT_GROSS
        .replace("kind", "u.kind")
        .replace("THEN ", "THEN u.");
    format!("WITH scoped AS MATERIALIZED (
        SELECT source,session_id,max(coalesce(ended_at,observed_at)) AS last_seen_at,{SUMS},{REQUESTS},{EVENT_GROSS}
        FROM usage_records WHERE {clause} AND session_id IS NOT NULL GROUP BY source,session_id
    ), page AS MATERIALIZED (
        SELECT scoped.* FROM scoped ORDER BY {order} LIMIT ? OFFSET ?
    ), lifetime AS (
        SELECT u.source,u.session_id,max(u.project_key) AS project_key,count(DISTINCT u.project_key) AS project_key_variants,
        min(u.observed_at) AS started_at,max(coalesce(u.ended_at,u.observed_at)) AS last_seen_at,
        {lifetime_sums},{lifetime_requests},{lifetime_events},max(u.kind='cumulative') AS has_cumulative
        FROM page CROSS JOIN usage_records u INDEXED BY idx_usage_session
        ON u.source=page.source AND u.session_id=page.session_id WHERE +u.active=1 GROUP BY u.source,u.session_id
    ) SELECT scoped.*,lifetime.project_key,lifetime.project_key_variants,lifetime.started_at,lifetime.last_seen_at,lifetime.has_cumulative,
        lifetime.input_tokens AS cumulative_input_tokens,lifetime.output_tokens AS cumulative_output_tokens,
        lifetime.cache_read_tokens AS cumulative_cache_read_tokens,lifetime.cache_write_tokens AS cumulative_cache_write_tokens,
        lifetime.cost_micros AS cumulative_cost_micros,lifetime.record_count AS cumulative_record_count,
        lifetime.unpriced_records AS cumulative_unpriced_records,lifetime.request_count AS cumulative_request_count,
        lifetime.event_gross_tokens AS cumulative_event_gross_tokens
        FROM page AS scoped JOIN lifetime USING(source,session_id) ORDER BY {order}")
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
        let mut points = rows(&self.db, &format!("SELECT {expr} AS bucket{group_select},{SUMS},{REQUESTS},{EVENT_GROSS} FROM usage_records WHERE {clause} AND (kind='event' OR (kind='cumulative' AND {same})) GROUP BY {group_by} ORDER BY bucket ASC"), &args)?;
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
        let order = if filter["from"].as_str().is_some_and(|v| !v.is_empty())
            || filter["to"].as_str().is_some_and(|v| !v.is_empty())
        {
            "coalesce(scoped.input_tokens,0)+coalesce(scoped.output_tokens,0)+coalesce(scoped.cache_read_tokens,0)+coalesce(scoped.cache_write_tokens,0) DESC,session_id ASC,source ASC"
        } else if ["model", "project"]
            .iter()
            .any(|key| filter[*key].as_str().is_some_and(|v| !v.is_empty()))
        {
            // Project/model filters limit the period sums, not the lifetime activity order.
            "(SELECT max(coalesce(sort.ended_at,sort.observed_at)) FROM usage_records sort INDEXED BY idx_usage_session WHERE sort.source=scoped.source AND sort.session_id=scoped.session_id AND +sort.active=1) DESC,session_id ASC,source ASC"
        } else {
            "scoped.last_seen_at DESC,session_id ASC,source ASC"
        };
        args.extend([json!(limit + 1), json!(offset)]);
        // Membership and period sums use exactly the totals scope. Lifetime metadata and
        // sums include all active rows of those (source, session_id) identities.
        let mut items = rows(&self.db, &session_sql(&clause, order), &args)?;
        let next = (items.len() > limit as usize).then(|| offset + limit as u64);
        items.truncate(limit as usize);
        for row in &mut items {
            if row["project_key_variants"] != 1 {
                row["project_key"] = Value::Null;
            }
            row.as_object_mut().unwrap().remove("project_key_variants");
            row["has_cumulative"] = json!(row["has_cumulative"] == 1);
            let mut cumulative = json!({});
            for key in [
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cost_micros",
                "record_count",
                "unpriced_records",
                "request_count",
                "event_gross_tokens",
            ] {
                cumulative[key] = row
                    .as_object_mut()
                    .unwrap()
                    .remove(&format!("cumulative_{key}"))
                    .unwrap();
            }
            row["cumulative"] = shape(cumulative);
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
        let row = rows(&self.db, &format!("SELECT min(observed_at) AS started_at,max(coalesce(ended_at,observed_at)) AS last_seen_at,{SUMS},{REQUESTS},{EVENT_GROSS},max(project_key) AS project_key,count(DISTINCT project_key) AS project_variants,sum(CASE WHEN kind='event' THEN 1 ELSE 0 END) AS event_records,sum(CASE WHEN kind='cumulative' THEN 1 ELSE 0 END) AS cumulative_records FROM usage_records WHERE {clause}"), &args)?.remove(0);
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
        let models: Vec<_> = rows(&self.db, &format!("SELECT model,{SUMS},{EVENT_GROSS} FROM usage_records WHERE {clause} GROUP BY model ORDER BY record_count DESC"), &args)?.into_iter().map(shape).collect();
        let timeline: Vec<_> = rows(&self.db, &format!("SELECT {expr} AS bucket,{SUMS},{REQUESTS},{EVENT_GROSS} FROM usage_records WHERE {clause} AND kind='event' GROUP BY bucket ORDER BY bucket ASC"), &args)?.into_iter().map(shape).collect();
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
        rows(&self.db,"SELECT model,provider,CASE WHEN instr(price_source,';')>0 THEN substr(price_source,instr(price_source,';')+1) ELSE '' END AS mark,count(*) AS records,sum(count(*)) OVER (PARTITION BY model) AS model_records FROM usage_records WHERE active=1 GROUP BY model,mark,provider ORDER BY sum(sum(coalesce(input_tokens,0)+coalesce(output_tokens,0)+coalesce(cache_read_tokens,0)+coalesce(cache_write_tokens,0))) OVER (PARTITION BY model) DESC,model,mark,provider", &[])
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
        Ok(rows(&self.db,&format!("SELECT {column} AS bucket,{SUMS},{REQUESTS},{EVENT_GROSS} FROM usage_records WHERE {clause} GROUP BY {column} ORDER BY cost_micros DESC,record_count DESC"),&args)?.into_iter().map(shape).collect())
    }
    pub fn grouped(&self, outer: &str, inner: &str, filter: &Value) -> Result<Vec<Value>> {
        let a = dimension(outer)?;
        let b = dimension(inner)?;
        let (clause, args) = scope(self, filter)?;
        Ok(rows(&self.db,&format!("SELECT {a} AS outer_key,{b} AS inner_key,{SUMS},{REQUESTS},{EVENT_GROSS} FROM usage_records WHERE {clause} GROUP BY outer_key,inner_key ORDER BY cost_micros DESC"),&args)?.into_iter().map(shape).collect())
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
        let mut row = self.output_last_run()?;
        if let Some(counts) = row.get_mut("counts").and_then(Value::as_object_mut) {
            let had_metadata = counts.keys().any(|key| key.starts_with("sync_trigger."));
            counts.retain(|key, _| {
                !key.starts_with("sync_trigger.") && !key.starts_with("sync_source.")
            });
            if had_metadata && counts.is_empty() {
                row["counts"] = Value::Null;
            }
        }
        Ok(row)
    }

    pub(crate) fn output_last_run(&self) -> Result<Value> {
        let Some(mut row)=rows(&self.db,"SELECT id,status,started_at,finished_at,attempted,inserted,updated,unchanged,rejected,notes,counts,skipped_files FROM ingest_runs LEFT JOIN ingest_run_files ON run_id=id ORDER BY id DESC LIMIT 1",&[])?.pop() else{return Ok(Value::Null)};
        if row["skipped_files"].as_i64().unwrap_or(0) == 0 {
            row.as_object_mut().unwrap().remove("skipped_files");
        }
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
    fn f1_prices_sort_by_displayed_tokens_then_model() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let mut records = vec![
            json!({"record_key":"large","source":"claude","model":"z-large","observed_at":"2026-01-15T00:00:00Z","input_tokens":1000}),
            json!({"record_key":"tie-b","source":"claude","model":"b-tie","observed_at":"2026-01-15T00:00:00Z","output_tokens":100}),
            json!({"record_key":"tie-a","source":"claude","model":"a-tie","observed_at":"2026-01-15T00:00:00Z","cache_read_tokens":60,"cache_write_tokens":40}),
        ];
        for i in 0..5 {
            records.push(json!({"record_key":format!("small-{i}"),"source":"claude","model":"frequent-small","observed_at":"2026-01-15T00:00:00Z","input_tokens":1}));
        }
        ledger
            .batch(&records, None, None, &[], pricing::cost_of)
            .unwrap();
        let response = crate::stats::service::pricing(&ledger, "UTC").unwrap();
        let names: Vec<_> = response["models"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["model"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["z-large", "a-tie", "b-tie", "frequent-small"]);
    }

    #[test]
    fn fix1_lifetime_lookup_is_indexed_and_follows_pagination() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let sql = session_sql(
            "+active=1",
            "scoped.last_seen_at DESC,session_id ASC,source ASC",
        );
        let plan = rows(
            &ledger.db,
            &format!("EXPLAIN QUERY PLAN {sql}"),
            &[json!(6), json!(0)],
        )
        .unwrap();
        println!("FIX1 EXPLAIN: {plan:?}");
        let details: Vec<_> = plan.iter().map(|r| r["detail"].as_str().unwrap()).collect();
        assert!(
            details.iter().any(|s| s
                .contains("SEARCH u USING INDEX idx_usage_session (source=? AND session_id=?)")),
            "{details:?}"
        );
        assert!(
            !details
                .iter()
                .any(|s| *s == "SCAN u" || s.starts_with("SCAN u ")),
            "{details:?}"
        );
        assert!(
            sql.contains("page AS MATERIALIZED"),
            "Lifetime must aggregate the selected page"
        );
    }

    #[test]
    fn fix1_event_gross_excludes_snapshots_and_counts_partial_tokens() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        ledger.batch(&[
            json!({"record_key":"event","source":"codex","session_id":"mixed","model":"m","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":100,"cache_read_tokens":30}),
            json!({"record_key":"snapshot","source":"codex","session_id":"mixed","model":"m","kind":"cumulative","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":10000}),
            json!({"record_key":"pure","source":"dsh","session_id":"snapshot","model":"s","kind":"cumulative","observed_at":"2026-01-15T00:00:00.000Z","output_tokens":900}),
        ], None,None,&[],pricing::cost_of).unwrap();
        let groups = ledger.breakdown("source", &json!({})).unwrap();
        let mixed = groups.iter().find(|r| r["bucket"] == "codex").unwrap();
        assert_eq!(mixed["gross_tokens"], 10130);
        assert_eq!(mixed["request_count"], 1);
        assert_eq!(mixed["event_gross_tokens"], 130);
        assert_eq!(
            groups.iter().find(|r| r["bucket"] == "dsh").unwrap()["event_gross_tokens"],
            0
        );
        assert_eq!(
            ledger
                .grouped("source", "model", &json!({}))
                .unwrap()
                .iter()
                .find(|r| r["outer_key"] == "codex")
                .unwrap()["event_gross_tokens"],
            130
        );
        let (sessions, _) = ledger
            .sessions(None, 0, &json!({"source":"codex"}))
            .unwrap();
        assert_eq!(sessions[0]["event_gross_tokens"], 130);
        assert_eq!(sessions[0]["cumulative"]["event_gross_tokens"], 130);
        let detail = ledger
            .session_detail("codex", "mixed", "day", 0)
            .unwrap()
            .unwrap();
        assert_eq!(detail["summary"]["event_gross_tokens"], 130);
        assert_eq!(detail["timeline"][0]["event_gross_tokens"], 130);
    }

    #[test]
    fn fix1_project_scope_preserves_lifetime_order_and_detail_totals() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        ledger.batch(&[
            json!({"record_key":"a1","source":"codex","session_id":"a","project_key":"target","observed_at":"2026-01-01T00:00:00.000Z","input_tokens":10}),
            json!({"record_key":"a2","source":"codex","session_id":"a","project_key":"other","observed_at":"2026-01-20T00:00:00.000Z","input_tokens":100}),
            json!({"record_key":"b1","source":"codex","session_id":"b","project_key":"target","observed_at":"2026-01-10T00:00:00.000Z","input_tokens":20}),
        ],None,None,&[],pricing::cost_of).unwrap();
        let (items, next) = ledger
            .sessions(Some(1), 0, &json!({"project":"target"}))
            .unwrap();
        assert_eq!(items[0]["session_id"], "a");
        assert_eq!(items[0]["gross_tokens"], 10);
        assert_eq!(items[0]["cumulative"]["gross_tokens"], 110);
        assert_eq!(next, Some(1));
        let filter =
            json!({"from":"2026-01-01","to":"2026-01-10","project":"target","source":"codex"});
        let (items, _) = ledger.sessions(Some(50), 0, &filter).unwrap();
        assert_eq!(items[0]["session_id"], "b");
        let mut params = filter;
        params["session_id"] = json!("a");
        params["granularity"] = json!("day");
        let detail = crate::stats::service::session_detail(&ledger, &params, 0, "UTC")
            .unwrap()
            .unwrap();
        assert_eq!(detail["period"]["gross_tokens"], items[1]["gross_tokens"]);
        assert_eq!(detail["period"]["request_count"], 1);
        assert_eq!(detail["period"]["event_gross_tokens"], 10);
        assert_eq!(detail["session"]["gross_tokens"], 110);
        assert_eq!(detail["session"]["request_count"], 2);
    }

    #[test]
    fn e3_session_attribution_requests_and_partition() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let event = |key: &str, session: Option<&str>, day: &str, n: i64| {
            json!({
                "record_key":key,"source":"codex","session_id":session,
                "project_key":"demo","model":"claude-fable-5-1","observed_at":format!("{day}T12:00:00.000Z"),
                "input_tokens":n,"output_tokens":n*2,"cache_read_tokens":n*3,"cache_write_tokens":n*4
            })
        };
        let mut snapshot = event("snapshot", Some("snapshot"), "2026-01-13", 50);
        snapshot["kind"] = json!("cumulative");
        snapshot["ended_at"] = json!("2026-01-15T13:00:00.000Z");
        ledger
            .batch(
                &[
                    event("old", Some("long"), "2025-12-15", 100),
                    event("resumed", Some("long"), "2026-01-15", 10),
                    event("new", Some("new"), "2026-01-15", 20),
                    event("anonymous", None, "2026-01-15", 3),
                    snapshot,
                ],
                None,
                None,
                &[],
                pricing::cost_of,
            )
            .unwrap();
        ledger
            .batch(
                &[event("inactive", Some("long"), "2026-01-15", 999)],
                None,
                None,
                &[],
                pricing::cost_of,
            )
            .unwrap();
        ledger
            .db
            .execute(
                "UPDATE usage_records SET active=0 WHERE record_key='inactive'",
                [],
            )
            .unwrap();
        let filter = json!({"from":"2026-01-15","to":"2026-01-15","offsetMinutes":0});
        let (items, next) = ledger.sessions(Some(1), 0, &filter).unwrap();
        assert_eq!(items[0]["session_id"], "new");
        assert_eq!(next, Some(1));
        let (items, next) = ledger.sessions(Some(50), 0, &filter).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(next, None);
        let long = items.iter().find(|r| r["session_id"] == "long").unwrap();
        assert_eq!(long["started_at"], "2025-12-15T12:00:00.000Z");
        assert_eq!(long["last_seen_at"], "2026-01-15T12:00:00.000Z");
        assert_eq!(long["request_count"], 1);
        assert_eq!(long["has_cumulative"], false);
        for (field, period, lifetime) in [
            ("input_tokens", 10, 110),
            ("output_tokens", 20, 220),
            ("cache_read_tokens", 30, 330),
            ("cache_write_tokens", 40, 440),
            ("gross_tokens", 100, 1100),
            ("request_count", 1, 2),
        ] {
            assert_eq!(long[field], period, "period {field}");
            assert_eq!(long["cumulative"][field], lifetime, "lifetime {field}");
        }
        assert!(long["cost_micros"].as_i64().unwrap() > 0);
        assert!(
            long["cumulative"]["cost_micros"].as_i64().unwrap()
                > long["cost_micros"].as_i64().unwrap()
        );
        let (clause, args) = scope(&ledger, &filter).unwrap();
        let anonymous = shape(
            rows(
                &ledger.db,
                &format!("SELECT {SUMS} FROM usage_records WHERE {clause} AND session_id IS NULL"),
                &args,
            )
            .unwrap()
            .remove(0),
        )["gross_tokens"]
            .as_i64()
            .unwrap();
        assert_eq!(anonymous, 30);
        assert_eq!(
            items
                .iter()
                .map(|r| r["gross_tokens"].as_i64().unwrap())
                .sum::<i64>()
                + anonymous,
            ledger.totals(&filter).unwrap()["gross_tokens"]
        );
        let (all, _) = ledger.sessions(None, 0, &json!({})).unwrap();
        assert_eq!(all[0]["session_id"], "snapshot");
        let snap = all.iter().find(|r| r["session_id"] == "snapshot").unwrap();
        assert_eq!(snap["request_count"], Value::Null);
        assert_eq!(snap["cumulative"]["request_count"], Value::Null);
        assert_eq!(snap["has_cumulative"], true);
        let groups = ledger.breakdown("source", &filter).unwrap();
        assert_eq!(groups[0]["request_count"], 3);
        assert_eq!(
            ledger
                .breakdown("source", &json!({"from":"2026-01-13","to":"2026-01-13"}))
                .unwrap()[0]["request_count"],
            Value::Null
        );
        assert_eq!(
            ledger.grouped("source", "model", &filter).unwrap()[0]["request_count"],
            3
        );
        let detail = ledger
            .session_detail("codex", "long", "day", 0)
            .unwrap()
            .unwrap();
        assert_eq!(detail["summary"]["request_count"], 2);
        assert_eq!(detail["timeline"][0]["request_count"], 1);
        assert_eq!(detail["timeline"][1]["request_count"], 1);
    }

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
