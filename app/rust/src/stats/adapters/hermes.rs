use super::super::{
    jscompat::{normalize_timestamp, string, LocalZone},
    Result,
};
use super::{
    lines::{empty, event},
    num::token_of,
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;

pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    let usage = sqlite::columns(&db, "session_model_usage", notes)?;
    let sessions = sqlite::columns(&db, "sessions", notes)?;
    let mut rows = Vec::new();
    if !usage.is_empty() {
        let time = if usage.contains("last_seen") {
            "last_seen"
        } else if usage.contains("first_seen") {
            "first_seen"
        } else {
            "NULL"
        };
        let write = if usage.contains("cache_write_tokens") {
            "cache_write_tokens"
        } else {
            "NULL"
        };
        let read = if usage.contains("cache_read_tokens") {
            "cache_read_tokens"
        } else {
            "NULL"
        };
        rows = sqlite::query(
            &db,
            &format!(
                r#"
        SELECT
          session_id,
          model,
          input_tokens,
          output_tokens,
          {read} AS cache_read_tokens,
          {write} AS cache_write_tokens,
          {time} AS event_time
        FROM session_model_usage
        ORDER BY {time} DESC
      "#
            ),
            &[],
            notes,
        )?;
    }
    if rows.is_empty() && !sessions.is_empty() {
        let time = if sessions.contains("last_activity_at") {
            "last_activity_at"
        } else if sessions.contains("started_at") {
            "started_at"
        } else {
            "NULL"
        };
        let write = if sessions.contains("cache_write_tokens") {
            "cache_write_tokens"
        } else {
            "NULL"
        };
        let read = if sessions.contains("cache_read_tokens") {
            "cache_read_tokens"
        } else {
            "NULL"
        };
        rows = sqlite::query(
            &db,
            &format!(
                r#"
        SELECT
          id AS session_id,
          model,
          input_tokens,
          output_tokens,
          {read} AS cache_read_tokens,
          {write} AS cache_write_tokens,
          {time} AS event_time
        FROM sessions
        WHERE (input_tokens > 0 OR output_tokens > 0 OR {read} > 0 OR {write} > 0)
        ORDER BY {time} DESC
      "#
            ),
            &[],
            notes,
        )?;
    }
    let mut out = Vec::new();
    for row in rows {
        let tokens = [
            token_of(&row, &["input_tokens"], notes),
            token_of(&row, &["output_tokens"], notes),
            token_of(&row, &["cache_read_tokens"], notes),
            token_of(&row, &["cache_write_tokens"], notes),
        ];
        if empty(&tokens, notes) {
            continue;
        }
        let session = if super::super::jscompat::truthy(&row["session_id"]) {
            string(&row["session_id"])
        } else {
            String::new()
        };
        let model = super::super::jscompat::truthy(&row["model"]).then(|| string(&row["model"]));
        let mut record = event(
            "hermes",
            format!(
                "hermes|{session}|{}",
                model.as_deref().unwrap_or("hermes-agent")
            ),
            session,
            model,
            normalize_timestamp(&row["event_time"], zone),
            tokens,
        );
        record["kind"] = json!("cumulative");
        out.push(record);
    }
    Ok(out)
}
