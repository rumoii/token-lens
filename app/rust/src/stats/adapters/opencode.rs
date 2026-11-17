use super::super::{
    jscompat::{normalize_timestamp, string, truthy, LocalZone},
    Error, Result,
};
use super::{
    lines::{empty, event, fallback, file_tag, note, nullish, trim},
    num::{plus, token_of},
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;

pub(super) fn parse(
    identity: &str,
    file: &Path,
    source: &str,
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    let v2 = sqlite::table_exists(&db, "session_message", notes)?;
    let v1 = sqlite::table_exists(&db, "message", notes)?;
    if !v1 && !v2 {
        return Ok(Vec::new());
    }
    let mut rows = Vec::new();
    let mut table = "session_v2";
    if v2 {
        rows = sqlite::query(
            &db,
            r#"
        SELECT id, session_id, time_updated, time_created, data
        FROM session_message
        WHERE type = 'assistant'
        ORDER BY time_updated ASC
      "#,
            &[],
            notes,
        )?;
    }
    if rows.is_empty() && v1 {
        table = "session";
        rows = sqlite::query(
            &db,
            r#"
        SELECT id, session_id, time_updated, time_created, data
        FROM message
        ORDER BY time_updated ASC
      "#,
            &[],
            notes,
        )?;
    }
    let directory = sqlite::directory_query(&db, table, "id", "directory", notes)?;
    let mut out = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let Some(text) = row["data"].as_str().filter(|s| !s.is_empty()) else {
            continue;
        };
        let data = match super::lines::json(text.as_bytes()) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        if data.is_null() {
            return Err(Error(
                "Cannot read properties of null (reading 'type')".into(),
            ));
        }
        if truthy(&data["type"])
            && data["type"] != "assistant"
            && truthy(&data["role"])
            && data["role"] != "assistant"
        {
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
        let session = fallback(&[&row["session_id"], &data["sessionID"], &data["session_id"]]);
        let session = if truthy(session) {
            string(session)
        } else {
            String::new()
        };
        let model = [&data["model"], &data["model"]["id"], &data["modelID"]]
            .into_iter()
            .find_map(|v| v.as_str().filter(|s| !s.is_empty()).map(str::to_owned));
        let provider = nullish(&[&data["model"]["providerID"], &data["providerID"]]);
        let time = normalize_timestamp(
            fallback(&[
                &row["time_updated"],
                &row["time_created"],
                &data["time"]["completed"],
                &data["time"]["created"],
            ]),
            zone,
        );
        let id = nullish(&[&row["id"], &data["id"]]);
        let key = if truthy(id) {
            format!("{source}|{session}|{}", string(id))
        } else {
            format!(
                "{source}|{session}|{}|{}|{index}",
                file_tag(identity),
                time.as_deref().unwrap_or("null")
            )
        };
        let mut record = event(source, key, session.clone(), model, time.clone(), values);
        if !truthy(id) {
            record["replaces"] = json!([format!(
                "{source}|{session}|{}",
                time.as_deref().unwrap_or("null")
            )]);
        }
        record["provider"] = json!(provider.as_str().filter(|s| !trim(s).is_empty()));
        record["project_key"] = json!(sqlite::directory(
            &db,
            &directory,
            &json!(session),
            "directory",
            notes
        )?);
        record["timing"] = super::timing::content_event(&data, &record["output_tokens"]);
        out.push(record);
    }
    Ok(out)
}
