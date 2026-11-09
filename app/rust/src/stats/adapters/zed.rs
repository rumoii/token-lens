use super::super::{
    jscompat::{normalize_timestamp, string, truthy, JsJson, LocalZone},
    Result,
};
use super::{
    lines::{empty, event, fallback, note},
    num::{plus, token_of},
    sqlite, zstd,
};
use serde_json::{json, Value};
use std::path::Path;
pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if !sqlite::table_exists(&db, "threads", notes)? {
        return Ok(Vec::new());
    }
    let rows = sqlite::query(
        &db,
        r#"
      SELECT id, updated_at, data_type, data
      FROM threads
      ORDER BY updated_at ASC
    "#,
        &[],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let data = &row["data"];
        if !truthy(data) || data.as_array().is_some_and(Vec::is_empty) || data.as_str() == Some("")
        {
            continue;
        }
        let bytes = match data {
            Value::Array(bytes) => bytes
                .iter()
                .map(|b| b.as_u64().unwrap_or(0) as u8)
                .collect(),
            Value::String(s) => s.as_bytes().to_vec(),
            _ => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let bytes = if row["data_type"] == "zstd" {
            match zstd::decode(&bytes) {
                Ok(b) => b,
                Err(_) => {
                    note(notes, "bad_lines");
                    continue;
                }
            }
        } else {
            bytes
        };
        let text = String::from_utf8_lossy(&bytes);
        if text.is_empty() {
            continue;
        }
        let parsed = match JsJson::parse(&text) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let thread = parsed.to_value();
        if (!thread.is_object() && !thread.is_array()) || thread["imported"] == true {
            continue;
        }
        let model = [&thread["model"], &thread["model"]["model"]]
            .into_iter()
            .find_map(|v| v.as_str().filter(|s| !s.is_empty()).map(str::to_owned));
        let mut values = [None; 4];
        for r in parsed.get("request_token_usage").values() {
            let r = r.to_value();
            if !r.is_object() && !r.is_array() {
                continue;
            }
            let round = [
                token_of(&r, &["input_tokens"], notes),
                token_of(&r, &["output_tokens"], notes),
                token_of(
                    &r,
                    &["cache_read_input_tokens", "cached_input_tokens"],
                    notes,
                ),
                token_of(&r, &["cache_creation_input_tokens"], notes),
            ];
            for i in 0..4 {
                values[i] = plus(values[i], round[i]);
            }
        }
        if values.iter().all(|v| v.unwrap_or(0) == 0) {
            let cum = &thread["cumulative_token_usage"];
            if cum.is_object() || cum.is_array() {
                values = [
                    token_of(cum, &["input_tokens"], notes),
                    token_of(cum, &["output_tokens"], notes),
                    token_of(
                        cum,
                        &["cache_read_input_tokens", "cached_input_tokens"],
                        notes,
                    ),
                    token_of(cum, &["cache_creation_input_tokens"], notes),
                ];
            }
        }
        if empty(&values, notes) {
            continue;
        }
        let session = string(fallback(&[&row["id"], &thread["id"], &json!("zed-thread")]));
        let time =
            normalize_timestamp(fallback(&[&thread["updated_at"], &row["updated_at"]]), zone);
        let mut record = event(
            "zed",
            format!("zed|{session}"),
            session,
            model,
            time,
            values,
        );
        record["kind"] = json!("cumulative");
        out.push(record);
    }
    Ok(out)
}
