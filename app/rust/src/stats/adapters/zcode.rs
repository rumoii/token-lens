use super::super::{
    jscompat::{normalize_timestamp, LocalZone},
    Result,
};
use super::{
    lines::{empty, event, note, trim},
    num::token_of,
    sqlite, timing,
};
use serde_json::{json, Value};
use std::path::Path;
pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if sqlite::get(
        &db,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'model_usage'",
        &[],
        notes,
    )?
    .is_none()
    {
        return Ok(Vec::new());
    }
    let directory = sqlite::directory_query(&db, "session", "id", "directory", notes)?;
    let columns = sqlite::query(&db, "PRAGMA table_info(model_usage)", &[], notes)?;
    let timing_columns = [
        "first_token_at",
        "completed_at",
        "time_to_first_token_ms",
        "status",
    ]
    .map(|name| {
        if columns.iter().any(|c| c["name"] == name) {
            name.to_owned()
        } else {
            format!("NULL AS {name}")
        }
    })
    .join(",");
    let rows = sqlite::query(
        &db,
        &format!(
            r#"
      SELECT id, session_id, model_id, provider_id, started_at,
        input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens,{timing_columns}
      FROM model_usage ORDER BY started_at, id
    "#
        ),
        &[],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let Some(id) = row["id"].as_str().filter(|s| !trim(s).is_empty()) else {
            note(notes, "bad_lines");
            continue;
        };
        let mut values = [
            token_of(&row, &["input_tokens"], notes),
            token_of(&row, &["output_tokens"], notes),
            token_of(&row, &["cache_read_input_tokens"], notes),
            token_of(&row, &["cache_creation_input_tokens"], notes),
        ];
        if let Some(input) = values[0] {
            let input = input - values[2].unwrap_or(0) - values[3].unwrap_or(0);
            values[0] = if input < 0 {
                note(notes, "bad_fields");
                None
            } else {
                Some(input)
            };
        }
        if empty(&values, notes) {
            continue;
        }
        let time = normalize_timestamp(&row["started_at"], zone);
        if time.is_none() {
            note(notes, "bad_times");
            continue;
        }
        let session = row["session_id"].as_str().filter(|s| !trim(s).is_empty());
        let model = row["model_id"]
            .as_str()
            .map(trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let mut record = event(
            "zcode",
            format!("zcode|{}|{id}", session.unwrap_or("-")),
            session.unwrap_or("").into(),
            model,
            time,
            values,
        );
        record["provider"] = json!(row["provider_id"].as_str().filter(|s| !trim(s).is_empty()));
        let first = timing::milliseconds(&row["first_token_at"]);
        let elapsed = |end: Option<i64>, start: Option<i64>| {
            end.zip(start)
                .and_then(|(end, start)| end.checked_sub(start))
                .filter(|ms| *ms >= 0)
        };
        let ttft = if row["time_to_first_token_ms"].is_null() {
            elapsed(first, timing::milliseconds(&row["started_at"]))
        } else {
            timing::milliseconds(&row["time_to_first_token_ms"])
        };
        let generation = elapsed(timing::milliseconds(&row["completed_at"]), first);
        let status = match row["status"].as_str() {
            Some("completed") => "completed",
            Some("error") => "failed",
            Some("cancelled") => "cancelled",
            Some("running") => "partial",
            _ => "unknown",
        };
        record["timing"] = timing::request(
            ttft,
            generation,
            "client_reported",
            status,
            &record["output_tokens"],
        );
        record["project_key"] = json!(if session.is_some() {
            sqlite::directory(&db, &directory, &row["session_id"], "directory", notes)?
        } else {
            None
        });
        record.as_object_mut().unwrap().remove("timestamp");
        out.push(record);
    }
    Ok(out)
}
