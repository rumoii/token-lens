use super::super::{
    jscompat::{normalize_timestamp, string, truthy, LocalZone},
    Result,
};
use super::{
    lines::{basename, empty, event, fallback},
    num::{plus, token_of},
    sqlite,
};
use serde_json::{json, Value};
use std::{collections::HashSet, path::Path};
pub(super) fn parse(
    identity: &str,
    file: &Path,
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    let events = sqlite::table_exists(&db, "assistant_usage_events", notes)?;
    let sessions = sqlite::table_exists(&db, "sessions", notes)?;
    if !events && !sessions {
        return Ok(Vec::new());
    }
    let mut detailed = HashSet::new();
    let sibling = file
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("session-store.db");
    if basename(identity) == "data.db" && sibling.exists() {
        // The recursive Node call omits notes; failures still propagate to the parent file.
        for record in parse("session-store.db", &sibling, zone, &mut json!({}))? {
            if record["kind"] == "event" && truthy(&record["observed_at"]) {
                detailed.insert(string(&record["session_id"]));
            }
        }
    }
    let mut out = Vec::new();
    if events {
        let cols = sqlite::columns(&db, "assistant_usage_events", notes).unwrap_or_default();
        let id = if cols.contains("id") {
            "id"
        } else {
            "NULL AS id"
        };
        let rows = sqlite::query(
            &db,
            &format!(
                r#"
        SELECT
          {id},
          session_id,
          model,
          input_tokens,
          output_tokens,
          cache_read_tokens,
          cache_write_tokens,
          reasoning_tokens,
          created_at
        FROM assistant_usage_events
        ORDER BY created_at ASC
      "#
            ),
            &[],
            notes,
        )?;
        let mut ordinal = 0;
        for row in rows {
            let values = [
                token_of(&row, &["input_tokens"], notes),
                plus(
                    token_of(&row, &["output_tokens"], notes),
                    token_of(&row, &["reasoning_tokens"], notes),
                ),
                token_of(&row, &["cache_read_tokens"], notes),
                token_of(&row, &["cache_write_tokens"], notes),
            ];
            if empty(&values, notes) {
                continue;
            }
            ordinal += 1;
            let session = string(fallback(&[&row["session_id"], &json!("copilot-session")]));
            let time = normalize_timestamp(&row["created_at"], zone);
            if time.is_some() {
                detailed.insert(session.clone());
            }
            let key = if row["id"].is_null() {
                format!(
                    "copilot|{session}|{}|{ordinal}",
                    time.as_deref().unwrap_or("null")
                )
            } else {
                format!("copilot|{session}|{}", string(&row["id"]))
            };
            let model = truthy(&row["model"]).then(|| string(&row["model"]));
            let mut record = event("copilot", key, session.clone(), model, time, values);
            record["replaces"] = json!([format!("copilot|{session}")]);
            out.push(record);
        }
    }
    if sessions {
        let rows = sqlite::query(
            &db,
            r#"
        SELECT
          id,
          model,
          total_input_tokens,
          total_output_tokens,
          total_cached_tokens,
          total_reasoning_tokens,
          coalesce(updated_at, created_at) AS event_time
        FROM sessions
        ORDER BY event_time ASC
      "#,
            &[],
            notes,
        )?;
        for row in rows {
            let values = [
                token_of(&row, &["total_input_tokens"], notes),
                plus(
                    token_of(&row, &["total_output_tokens"], notes),
                    token_of(&row, &["total_reasoning_tokens"], notes),
                ),
                token_of(&row, &["total_cached_tokens"], notes),
                None,
            ];
            if empty(&values, notes) {
                continue;
            }
            let session = string(fallback(&[&row["id"], &json!("copilot-app-session")]));
            if detailed.contains(&session) {
                continue;
            }
            let model = truthy(&row["model"]).then(|| string(&row["model"]));
            let mut record = event(
                "copilot",
                format!("copilot|{session}"),
                session,
                model,
                normalize_timestamp(&row["event_time"], zone),
                values,
            );
            record["kind"] = json!("cumulative");
            out.push(record);
        }
    }
    Ok(out)
}
