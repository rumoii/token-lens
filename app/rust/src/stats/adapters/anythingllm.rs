use super::super::{
    jscompat::{normalize_timestamp, string, LocalZone},
    Result,
};
use super::{
    lines::{empty, note, trim},
    num::token_of,
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;
fn sql_datetime(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 19
        && b[..19].iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b' ',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        })
        && (b.len() == 19
            || b.len() > 20 && b[19] == b'.' && b[20..].iter().all(u8::is_ascii_digit))
}
pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if sqlite::get(
        &db,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_chats'",
        &[],
        notes,
    )?
    .is_none()
    {
        return Ok(Vec::new());
    }
    let rows = sqlite::query(&db, "SELECT * FROM workspace_chats ORDER BY id", &[], notes)?;
    let mut out = Vec::new();
    for row in rows {
        let response = match sqlite::json_parse(row.get("response")) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let metrics = &response["metrics"];
        if !metrics.is_object() {
            continue;
        }
        let input = token_of(metrics, &["prompt_tokens"], notes);
        let output = token_of(metrics, &["completion_tokens"], notes);
        if empty(&[input, output], notes) {
            continue;
        }
        let raw = if let Some(s) = row["createdAt"].as_str().filter(|s| sql_datetime(s)) {
            json!(format!("{}Z", s.replacen(' ', "T", 1)))
        } else {
            row["createdAt"].clone()
        };
        let time = normalize_timestamp(&raw, zone);
        if time.is_none() {
            note(notes, "bad_times");
            continue;
        }
        let workspace = row
            .get("workspaceId")
            .map(string)
            .unwrap_or_else(|| "undefined".into());
        let id = row
            .get("id")
            .map(string)
            .unwrap_or_else(|| "undefined".into());
        let session = if !row["api_session_id"].is_null() {
            format!("api:{}", string(&row["api_session_id"]))
        } else {
            format!(
                "thread:{}",
                row.get("thread_id")
                    .filter(|v| !v.is_null())
                    .map(string)
                    .unwrap_or_else(|| "main".into())
            )
        };
        let mut record = json!({"record_key":format!("anythingllm|{workspace}|{id}"),"source":"anythingllm","session_id":format!("{workspace}|{session}"),"project_key":null,"model":metrics["model"].as_str().map(trim).filter(|s|!s.is_empty()),"provider":metrics["provider"].as_str().map(trim).filter(|s|!s.is_empty()),"observed_at":time,"kind":"event","input_tokens":input,"output_tokens":output,"cache_read_tokens":null,"cache_write_tokens":null});
        record["timing"] = super::timing::duration(
            super::timing::seconds(&metrics["duration"]),
            "client_reported",
            "completed",
            &record["output_tokens"],
        );
        out.push(record);
    }
    Ok(out)
}
