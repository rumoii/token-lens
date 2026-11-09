use super::super::{
    jscompat::{normalize_timestamp, string, truthy, LocalZone},
    Result,
};
use super::{
    lines::{empty, event, note, trim},
    num::{plus, token_of},
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;
pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if sqlite::get(
        &db,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_message'",
        &[],
        notes,
    )?
    .is_none()
    {
        return Ok(Vec::new());
    }
    let directory = sqlite::directory_query(&db, "session", "id", "directory", notes)?;
    let rows = sqlite::query(
        &db,
        r#"
      SELECT id, session_id, data FROM session_message
      WHERE type = 'assistant' ORDER BY time_created, id
    "#,
        &[],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let data = match sqlite::json_parse(row.get("data")) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        if !data.is_object() || !truthy(&row["id"]) || !truthy(&row["session_id"]) {
            note(notes, "bad_lines");
            continue;
        }
        let tokens = &data["tokens"];
        if !tokens.is_object() && !tokens.is_array() {
            continue;
        }
        let values = [
            token_of(tokens, &["input"], notes),
            plus(
                token_of(tokens, &["output"], notes),
                token_of(tokens, &["reasoning"], notes),
            ),
            token_of(&tokens["cache"], &["read"], notes),
            token_of(&tokens["cache"], &["write"], notes),
        ];
        if empty(&values, notes) {
            continue;
        }
        let time = normalize_timestamp(&data["time"]["created"], zone);
        if time.is_none() {
            note(notes, "bad_times");
            continue;
        }
        let model = data["model"]["id"]
            .as_str()
            .map(trim)
            .filter(|s| !s.is_empty() && *s != "legacy")
            .map(str::to_owned);
        let mut record = event(
            "kilo",
            format!("kilo|{}|{}", string(&row["session_id"]), string(&row["id"])),
            string(&row["session_id"]),
            model,
            time,
            values,
        );
        record["session_id"] = row["session_id"].clone();
        record["provider"] = json!(data["model"]["providerID"]
            .as_str()
            .filter(|s| !trim(s).is_empty()));
        record["project_key"] = json!(sqlite::directory(
            &db,
            &directory,
            &row["session_id"],
            "directory",
            notes
        )?);
        record.as_object_mut().unwrap().remove("timestamp");
        record
            .as_object_mut()
            .unwrap()
            .remove("cache_creation_tokens");
        out.push(record);
    }
    Ok(out)
}
