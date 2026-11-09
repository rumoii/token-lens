use super::super::{
    jscompat::{normalize_timestamp, string, truthy, LocalZone},
    Result,
};
use super::{
    lines::{empty, event, note, trim},
    num::token_of,
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;
pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if sqlite::get(
        &db,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'local_runtime_token_usage'",
        &[],
        notes,
    )?
    .is_none()
    {
        return Ok(Vec::new());
    }
    let directory = sqlite::directory_query(
        &db,
        "local_runtime_sessions",
        "session_id",
        "workspace_dir",
        notes,
    )?;
    let rows = sqlite::query(
        &db,
        r#"
      SELECT id, session_id, model, ts, input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens
      FROM local_runtime_token_usage ORDER BY ts, id
    "#,
        &[],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let Some(session) = row["session_id"].as_str().filter(|s| !trim(s).is_empty()) else {
            note(notes, "bad_lines");
            continue;
        };
        if !truthy(&row["id"]) {
            note(notes, "bad_lines");
            continue;
        }
        let values = [
            token_of(&row, &["input_tokens"], notes),
            token_of(&row, &["output_tokens"], notes),
            token_of(&row, &["cache_read_tokens"], notes),
            token_of(&row, &["cache_write_tokens"], notes),
        ];
        if empty(&values, notes) {
            continue;
        }
        let time = normalize_timestamp(&row["ts"], zone);
        if time.is_none() {
            note(notes, "bad_times");
            continue;
        }
        let model = row["model"]
            .as_str()
            .map(trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let mut record = event(
            "minimax",
            format!("minimax|{session}|{}", string(&row["id"])),
            session.into(),
            model,
            time,
            values,
        );
        record["provider"] = Value::Null;
        record["project_key"] = json!(sqlite::directory(
            &db,
            &directory,
            &row["session_id"],
            "workspace_dir",
            notes
        )?);
        record.as_object_mut().unwrap().remove("timestamp");
        out.push(record);
    }
    Ok(out)
}
