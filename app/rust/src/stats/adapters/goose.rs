use super::super::{
    jscompat::{normalize_timestamp, string, truthy, LocalZone},
    Result,
};
use super::{
    lines::{empty, event, fallback, trim},
    num::token,
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;

pub(super) fn parse(file: &Path, zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    if !sqlite::table_exists(&db, "sessions", notes)? {
        return Ok(Vec::new());
    }
    let cols = sqlite::columns(&db, "sessions", notes).unwrap_or_default();
    let acc = cols.contains("accumulated_input_tokens");
    let input = if acc {
        "coalesce(accumulated_input_tokens, input_tokens)"
    } else {
        "input_tokens"
    };
    let output = if acc {
        "coalesce(accumulated_output_tokens, output_tokens)"
    } else {
        "output_tokens"
    };
    let total = if acc {
        "coalesce(accumulated_total_tokens, total_tokens)"
    } else {
        "total_tokens"
    };
    let provider = if cols.contains("provider_name") {
        "provider_name"
    } else {
        "NULL AS provider_name"
    };
    let rows = sqlite::query(
        &db,
        &format!(
            r#"
      SELECT
        id,
        model_config_json,
        {provider},
        created_at,
        {input} AS input_tokens,
        {output} AS output_tokens,
        {total} AS total_tokens
      FROM sessions
      ORDER BY created_at ASC
    "#
        ),
        &[],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let tokens = [
            token(&row["input_tokens"], notes),
            token(&row["output_tokens"], notes),
            None,
            None,
        ];
        if empty(&tokens, notes) {
            continue;
        }
        let session = string(fallback(&[&row["id"], &json!("goose-session")]));
        let model = row["model_config_json"]
            .as_str()
            .and_then(|s| sqlite::json_parse(Some(&json!(s))).ok())
            .and_then(|obj| {
                let m = fallback(&[&obj["model_name"], &obj["model"], &obj["modelId"]]);
                truthy(m).then(|| trim(&string(m)).to_owned())
            });
        let mut record = event(
            "goose",
            format!("goose|{session}"),
            session,
            model,
            normalize_timestamp(&row["created_at"], zone),
            tokens,
        );
        record["kind"] = json!("cumulative");
        record["provider"] = json!(row["provider_name"]
            .as_str()
            .filter(|s| !trim(s).is_empty()));
        out.push(record);
    }
    Ok(out)
}
