use super::{
    adapters::PARSER_REV,
    clock::Clock,
    ledger::{Ledger, ReadOpenError, LEDGER_VERSION},
    pricing, Error, Result,
};
use chrono::DateTime;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::Write,
    path::{Path, PathBuf},
};

pub(crate) const GROUPS: [&str; 6] = ["tool", "model", "project", "day", "hour", "month"];
const METRICS: [&str; 12] = [
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "total_tokens",
    "record_count",
    "request_count",
    "session_count",
    "cost_usd",
    "cost_micros",
    "currency",
    "unpriced_records",
];

pub(crate) fn read<T>(
    directory: &Path,
    clock: Clock,
    query: impl FnOnce(&Ledger) -> Result<T>,
) -> std::result::Result<T, ReadOpenError> {
    let ledger = Ledger::open_read_only(&directory.join("ledger.db"), clock)?;
    let transaction = ledger
        .db
        .unchecked_transaction()
        .map_err(|error| ReadOpenError::Unavailable(error.into()))?;
    ledger.check_read_version()?;
    let result = query(&ledger).map_err(ReadOpenError::Unavailable)?;
    transaction
        .commit()
        .map_err(|error| ReadOpenError::Unavailable(error.into()))?;
    Ok(result)
}

fn project_parts(path: &str) -> impl DoubleEndedIterator<Item = &str> {
    path.split(['/', '\\']).filter(|part| !part.is_empty())
}

pub(super) fn project_names<'a>(
    projects: impl IntoIterator<Item = &'a str>,
) -> HashMap<&'a str, String> {
    let mut basenames: HashMap<&str, Vec<&str>> = HashMap::new();
    for path in projects {
        if let Some(name) = project_parts(path).next_back() {
            let peers = basenames.entry(name).or_default();
            if !peers.contains(&path) {
                peers.push(path);
            }
        }
    }
    basenames
        .into_iter()
        .flat_map(|(name, peers)| {
            let duplicate = peers.len() > 1;
            peers.into_iter().map(move |path| {
                let label = if duplicate {
                    project_parts(path)
                        .rev()
                        .nth(1)
                        .map_or_else(|| name.into(), |parent| format!("{parent} / {name}"))
                } else {
                    name.into()
                };
                (path, label)
            })
        })
        .collect()
}

pub(crate) struct Scope {
    pub period: String,
    pub filter: Value,
    pub timezone: String,
    pub paths: bool,
}

impl Scope {
    fn resolve(&self, ledger: &Ledger) -> Result<(Value, Value)> {
        let mut filter = self.filter.clone();
        let mut project_label = Value::Null;
        let mut project_path = Value::Null;
        if let Some(project) = self.filter["project"]
            .as_str()
            .filter(|value| !value.is_empty())
        {
            filter["project"] = Value::Null;
            let paths = ledger.output_projects(&filter)?;
            let names = project_names(paths.iter().map(String::as_str));
            let exact = paths.iter().any(|path| path == project);
            let matches: Vec<_> = paths
                .iter()
                .filter(|path| {
                    if exact {
                        return *path == project;
                    }
                    names
                        .get(path.as_str())
                        .is_some_and(|label| label == project)
                        || project_parts(path).next_back() == Some(project)
                })
                .collect();
            project_label = if exact {
                project_path = json!(project);
                json!(names.get(project))
            } else if names.values().any(|label| label == project) {
                json!(project)
            } else {
                json!(project_parts(project).next_back())
            };
            filter["projectPaths"] = json!(matches);
        }
        let mut filters =
            json!({"tool":filter["source"],"model":filter["model"],"project":project_label});
        if self.paths {
            filters["project_path"] = project_path;
        }
        let query = json!({
            "period":self.period,"from":filter["from"],"to":filter["to"],
            "timezone":self.timezone,"filters":filters
        });
        Ok((filter, query))
    }
}

fn metrics(row: &Value) -> Value {
    // The ledger sums priced rows and supplies zero when the range is empty.
    let micros = row["cost_micros"].as_i64();
    json!({
        "input_tokens":row["input_tokens"],"output_tokens":row["output_tokens"],
        "cache_read_tokens":row["cache_read_tokens"],"cache_write_tokens":row["cache_write_tokens"],
        "total_tokens":row["gross_tokens"],"record_count":row["record_count"],
        "request_count":row["request_count"].as_i64().unwrap_or_default(),
        "session_count":row["session_count"].as_i64().unwrap_or_default(),
        "unpriced_records":row["unpriced_records"].as_i64().unwrap_or_default(),
        "cost_micros":micros,"cost_usd":pricing::format_micros(micros,6),"currency":"USD",
    })
}

fn difference(current: &Value, previous: &Value) -> Result<Value> {
    let mut delta = json!({});
    for field in METRICS {
        delta[field] = match (current[field].as_i64(), previous[field].as_i64()) {
            (Some(a), Some(b)) => json!(a
                .checked_sub(b)
                .ok_or_else(|| Error("Difference out of range".into()))?),
            _ => Value::Null,
        };
    }
    delta["currency"] = json!("USD");
    delta["cost_usd"] = json!(pricing::format_micros(delta["cost_micros"].as_i64(), 6));
    Ok(delta)
}

fn iso_seconds(value: &Value) -> Value {
    value
        .as_i64()
        .and_then(|seconds| DateTime::from_timestamp(seconds, 0))
        .map_or(Value::Null, |time| {
            json!(time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        })
}

fn last_run(ledger: &Ledger) -> Result<Value> {
    let row = ledger.output_last_run()?;
    if row.is_null() {
        return Ok(Value::Null);
    }
    let trigger = ["manual", "startup", "timer", "reread", "cli"]
        .into_iter()
        .find(|name| row["counts"][format!("sync_trigger.{name}")] == 1);
    let counts = ["attempted", "inserted", "updated", "unchanged", "rejected"]
        .into_iter()
        .map(|key| (key.to_owned(), row[key].clone()))
        .collect::<serde_json::Map<_, _>>();
    let finished_at = row["finished_at"].as_i64();
    let age = finished_at.map(|time| (ledger.clock.millis().div_euclid(1000) - time).max(0));
    Ok(json!({
        "started_at":iso_seconds(&row["started_at"]),"finished_at":iso_seconds(&row["finished_at"]),
        "status":row["status"],"trigger":trigger,"age_seconds":age,"counts":counts,
    }))
}

pub(crate) fn envelope(
    command: &str,
    clock: &Clock,
    last_run: &Value,
    query: Value,
    data: Value,
) -> Value {
    json!({
        "format_version":1,"command":command,"generated_at":clock.iso(),
        "freshness":{"last_sync_at":last_run["finished_at"],"last_sync_status":last_run["status"],"age_seconds":last_run["age_seconds"]},
        "query":query,"data":data
    })
}

pub(crate) fn static_query(timezone: &str) -> Value {
    json!({"period":null,"from":null,"to":null,"timezone":timezone,"filters":{}})
}

pub(crate) fn status(ledger: &Ledger, timezone: &str) -> Result<Value> {
    let last = last_run(ledger)?;
    Ok(envelope(
        "status",
        &ledger.clock,
        &last,
        static_query(timezone),
        json!({
            "ledger_version":LEDGER_VERSION,"price_version":ledger.prices.version(),
            "last_sync":last,"tools_with_usage":ledger.source_status()?.len()
        }),
    ))
}

pub(crate) fn sources(ledger: &Ledger, timezone: &str) -> Result<Value> {
    let used: HashMap<_, _> = ledger
        .source_status()?
        .into_iter()
        .map(|row| (row["source"].as_str().unwrap().to_owned(), row))
        .collect();
    let results = ledger.output_source_results()?;
    let mut tools: Vec<_> = PARSER_REV
        .iter()
        .map(|(id, _)| *id)
        .chain(used.keys().map(String::as_str))
        .collect();
    tools.sort_unstable();
    tools.dedup();
    let entries: Vec<_> = tools.into_iter().map(|id| {
        let usage = used.get(id).unwrap_or(&Value::Null);
        let last_sync_status = match results.get(id).and_then(Value::as_i64) {
            Some(1) => Some("ok"),
            Some(2) => Some("completed_with_anomalies"),
            Some(3) => Some("failed"),
            _ => None,
        };
        json!({"tool":id,"name":tool_name(id),"record_count":usage["records"].as_i64().unwrap_or_default(),
            "first_observed_at":usage["first_observed_at"],"last_observed_at":usage["last_observed_at"],
            "last_sync_status":last_sync_status})
    }).collect();
    Ok(envelope(
        "sources",
        &ledger.clock,
        &last_run(ledger)?,
        static_query(timezone),
        json!({"sources":entries}),
    ))
}

pub(super) fn tool_name(id: &str) -> &str {
    match id {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "qwen" => "Qwen Code",
        "dsh" => "DSH",
        "grok" => "Grok CLI",
        "anythingllm" => "AnythingLLM",
        "commandcode" => "Command Code",
        "aider" => "Aider",
        "pi" => "Pi",
        "hermes" => "Hermes",
        "cline" => "Cline",
        "gemini" => "Gemini CLI",
        "antigravity" => "Antigravity",
        "cursor" => "Cursor",
        "opencode" => "OpenCode",
        "kilo" => "Kilo Code",
        "openhands" => "OpenHands CLI",
        "goose" => "Goose",
        "zed" => "Zed",
        "continue" => "Continue",
        "trae" => "Trae",
        "copilot" => "Copilot",
        "openclaw" => "OpenClaw",
        "mimo" => "MiMo Code",
        "kimi" => "Kimi",
        "minimax" => "MiniMax Code",
        "zcode" => "ZCode",
        "codebuddy" => "CodeBuddy",
        _ => id,
    }
}

pub(crate) fn summary(ledger: &Ledger, scope: &Scope, prior: Option<&Scope>) -> Result<Value> {
    let (filter, query) = scope.resolve(ledger)?;
    let current = metrics(&ledger.output_totals(&filter)?);
    let data = if let Some(prior) = prior {
        let (filter, query) = prior.resolve(ledger)?;
        let previous = metrics(&ledger.output_totals(&filter)?);
        json!({"current":current,"previous":{"query":query,"totals":previous},"delta":difference(&current,&previous)?})
    } else {
        current
    };
    Ok(envelope(
        "summary",
        &ledger.clock,
        &last_run(ledger)?,
        query,
        data,
    ))
}

pub(crate) fn breakdown(ledger: &Ledger, scope: &Scope, by: &str) -> Result<Value> {
    let (filter, query) = scope.resolve(ledger)?;
    let rows = ledger.output_groups(by, &filter)?;
    let names = if by == "project" {
        project_names(rows.iter().filter_map(|row| row["bucket"].as_str()))
    } else {
        HashMap::new()
    };
    let groups: Vec<_> = rows
        .iter()
        .map(|row| {
            let mut data = metrics(row);
            if by == "project" {
                data["key"] = json!(row["bucket"].as_str().and_then(|path| names.get(path)));
                if scope.paths {
                    data["project_path"] = row["bucket"].clone();
                }
            } else {
                data["key"] = row["bucket"].clone();
            }
            data
        })
        .collect();
    Ok(envelope(
        "breakdown",
        &ledger.clock,
        &last_run(ledger)?,
        query,
        json!({"by":by,"rows":groups}),
    ))
}

pub(crate) fn cursor_scope(scope: &Scope, sort: &str) -> String {
    format!(
        "{:x}",
        Sha256::digest(json!([scope.filter, scope.period, scope.timezone, sort]).to_string())
    )
}

pub(crate) fn parse_cursor(cursor: &str, scope: &str, sort: &str) -> Option<[Value; 4]> {
    if cursor.len() > 131072 || !cursor.len().is_multiple_of(2) {
        return None;
    }
    let bytes = cursor
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let hi = (pair[0] as char).to_digit(16)?;
            let lo = (pair[1] as char).to_digit(16)?;
            Some((hi * 16 + lo) as u8)
        })
        .collect::<Option<Vec<_>>>()?;
    let (owner, keys): (String, [Value; 4]) = serde_json::from_slice(&bytes).ok()?;
    (owner == scope
        && matches!(keys[0].as_i64(), Some(0 | 1))
        && if sort == "recent" {
            keys[1].is_string()
        } else {
            keys[1].as_i64().is_some()
        }
        && keys[2].is_string()
        && keys[3].is_string())
    .then_some(keys)
}

fn next_cursor(owner: &str, row: &Value) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    json!([
        owner,
        [
            row["missing"],
            row["rank"],
            row["session_id"],
            row["source"]
        ]
    ])
    .to_string()
    .bytes()
    .flat_map(|byte| {
        [
            HEX[(byte >> 4) as usize] as char,
            HEX[(byte & 15) as usize] as char,
        ]
    })
    .collect()
}

fn with_project(data: &mut Value, row: &Value, names: &HashMap<&str, String>, paths: bool) {
    data["project"] = json!(row["project_key"].as_str().and_then(|path| names.get(path)));
    if paths {
        data["project_path"] = row["project_key"].clone();
    }
}

pub(crate) fn sessions(
    ledger: &Ledger,
    scope: &Scope,
    sort: &str,
    limit: usize,
    after: Option<&[Value; 4]>,
) -> Result<Value> {
    let (filter, mut query) = scope.resolve(ledger)?;
    query["sort"] = json!(sort);
    query["limit"] = json!(limit);
    let mut rows = ledger.output_sessions(&filter, sort, limit, after)?;
    let more = rows.len() > limit;
    rows.truncate(limit);
    let next = if more {
        rows.last()
            .map(|row| next_cursor(&cursor_scope(scope, sort), row))
    } else {
        None
    };
    let names = project_names(rows.iter().filter_map(|row| row["project_key"].as_str()));
    let items: Vec<_> = rows
        .iter()
        .map(|row| {
            let mut data = metrics(row);
            data["session_count"] = json!(1);
            data["tool"] = row["source"].clone();
            data["session_id"] = row["session_id"].clone();
            data["started_at"] = row["started_at"].clone();
            data["last_seen_at"] = row["last_seen_at"].clone();
            with_project(&mut data, row, &names, scope.paths);
            data
        })
        .collect();
    Ok(envelope(
        "sessions",
        &ledger.clock,
        &last_run(ledger)?,
        query,
        json!({"items":items,"next_cursor":next}),
    ))
}

pub(crate) fn session(
    ledger: &Ledger,
    timezone: &str,
    tool: &str,
    id: &str,
    paths: bool,
) -> Result<Value> {
    let filter = json!({"source":tool,"session":id});
    let row = ledger.output_totals(&filter)?;
    let mut query = static_query(timezone);
    query["filters"] = json!({"tool":tool,"session_id":id});
    let mut data = metrics(&row);
    data["tool"] = json!(tool);
    data["session_id"] = json!(id);
    data["started_at"] = row["started_at"].clone();
    data["last_seen_at"] = row["last_seen_at"].clone();
    let names = project_names(row["project_key"].as_str());
    with_project(&mut data, &row, &names, paths);
    let models: Vec<_> = ledger
        .output_groups("model", &filter)?
        .iter()
        .map(|row| {
            let mut model = metrics(row);
            model["model"] = row["bucket"].clone();
            model
        })
        .collect();
    data["models"] = json!(models);
    Ok(envelope(
        "session",
        &ledger.clock,
        &last_run(ledger)?,
        query,
        data,
    ))
}

pub(crate) fn sync_data(sync: &crate::api::stats::StatsSync) -> Value {
    json!({"attempted":sync.attempted,"inserted":sync.inserted,"updated":sync.updated,
        "unchanged":sync.unchanged,"rejected":sync.rejected,"repriced":sync.repriced,
        "file_count":sync.file_count,"parsed_files":sync.parsed_files,"cached_files":sync.cached_files,
        "skipped_files":sync.skipped_files,"duration_ms":sync.duration_ms})
}

pub(crate) fn sync_result(ledger: &Ledger, timezone: &str, data: Value) -> Result<Value> {
    Ok(envelope(
        "sync",
        &ledger.clock,
        &last_run(ledger)?,
        static_query(timezone),
        data,
    ))
}

pub(crate) fn encode(doc: &Value, pretty: bool) -> Result<Vec<u8>> {
    let mut bytes = if pretty {
        serde_json::to_vec_pretty(doc)?
    } else {
        serde_json::to_vec(doc)?
    };
    bytes.push(b'\n');
    Ok(bytes)
}

fn csv_cell(text: &str) -> String {
    let safe = if text.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        format!("'{text}")
    } else {
        text.to_owned()
    };
    if safe.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", safe.replace('"', "\"\""))
    } else {
        safe
    }
}

fn write_csv(mut writer: impl Write, doc: &Value, with_path: bool) -> Result<()> {
    let mut columns = vec!["key"];
    if with_path {
        columns.push("project_path");
    }
    columns.extend(METRICS);
    write!(writer, "\u{FEFF}{}\r\n", columns.join(","))?;
    for row in doc["data"]["rows"].as_array().unwrap() {
        let cells: Vec<_> = columns
            .iter()
            .map(|column| {
                let value = &row[*column];
                match value {
                    Value::Null => String::new(),
                    Value::String(text) => csv_cell(text),
                    other => csv_cell(&other.to_string()),
                }
            })
            .collect();
        write!(writer, "{}\r\n", cells.join(","))?;
    }
    Ok(())
}

pub(crate) fn export(
    directory: &Path,
    format: &str,
    by: &str,
    scope: &Scope,
    doc: &Value,
) -> Result<PathBuf> {
    if !directory.is_absolute() || !matches!(format, "csv" | "json") {
        return Err(Error(
            "Choose an absolute export directory and CSV or JSON".into(),
        ));
    }
    let from = scope.filter["from"].as_str().unwrap_or("all");
    let to = scope.filter["to"].as_str().unwrap_or("all");
    let stem = format!("token-lens-{by}-{from}-{to}");
    std::fs::create_dir_all(directory)?;
    let mut output = tempfile::NamedTempFile::new_in(directory)?;
    if format == "json" {
        output.write_all(&encode(doc, false)?)?;
    } else {
        write_csv(&mut output, doc, scope.paths && by == "project")?;
    }
    output.as_file().sync_all()?;
    for index in 1.. {
        let name = if index == 1 {
            format!("{stem}.{format}")
        } else {
            format!("{stem}-{index}.{format}")
        };
        let path = directory.join(name);
        match output.persist_noclobber(&path) {
            Ok(_) => return Ok(path),
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                output = error.file
            }
            Err(error) => return Err(error.error.into()),
        }
    }
    unreachable!()
}
