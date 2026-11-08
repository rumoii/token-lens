use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

use super::super::jscompat::JsJson;
use sha2::{Digest, Sha256};
fn nullish_js(values: &[&JsJson]) -> JsJson {
    values
        .iter()
        .find(|v| !matches!(v, JsJson::Null))
        .map_or(JsJson::Null, |v| (*v).clone())
}
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let text = String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let mut out = Vec::new();
    let mut ordinal = 0;
    let default = basename(identity)
        .split('.')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("openclaw-session");
    for line in text.split('\n') {
        let line = trim(line);
        if line.is_empty() {
            continue;
        }
        let raw = match JsJson::parse(line) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let row = raw.to_value();
        if !row.is_object() && !row.is_array() {
            continue;
        }
        let msg = fallback(&[&row["message"], &row]);
        let u = fallback(&[&msg["usage"], &row["usage"]]);
        if !u.is_object() && !u.is_array() {
            continue;
        }
        let role = fallback(&[&msg["role"], &row["role"]]);
        if jscompat::truthy(role) && role != "assistant" && role != "model" {
            continue;
        }
        let tokens = [
            token_of(u, &["input", "prompt_tokens", "input_tokens"], notes),
            token_of(u, &["output", "completion_tokens", "output_tokens"], notes),
            token_of(
                u,
                &["cacheRead", "cache_read_tokens", "cachedTokens"],
                notes,
            ),
            token_of(u, &["cacheWrite", "cache_write_tokens"], notes),
        ];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let session = optional(nullish(&[
            &row["session_id"],
            &row["sessionId"],
            &row["id"],
        ]))
        .unwrap_or_else(|| default.into());
        let time = jscompat::normalize_timestamp(
            nullish(&[&row["timestamp"], &row["created_at"], &row["time"]]),
            zone,
        );
        let raw_msg = if jscompat::truthy(&row["message"]) {
            raw.get("message")
        } else {
            &raw
        };
        let raw_role = if jscompat::truthy(&msg["role"]) {
            raw_msg.get("role")
        } else {
            raw.get("role")
        };
        let content = nullish_js(&[
            raw_msg.get("content"),
            raw_msg.get("text"),
            raw.get("content"),
        ]);
        let id = JsJson::Array(vec![
            time.as_ref()
                .map_or(JsJson::Null, |s| JsJson::String(s.encode_utf16().collect())),
            raw.get("id").clone(),
            raw_msg.get("id").clone(),
            raw_role.clone(),
            content,
            raw_msg.get("tool_calls").clone(),
        ])
        .stringify();
        let hash = format!("{:x}", Sha256::digest(id.as_bytes()));
        let mut r = event(
            "openclaw",
            format!("openclaw|c{hash}"),
            session.clone(),
            optional(nullish(&[&msg["model"], &row["model"]])),
            time.clone(),
            tokens,
        );
        r["replaces"] = json!([format!(
            "openclaw|{session}|{}|{ordinal}",
            time.as_deref().unwrap_or("null")
        )]);
        r["provider"] = json!(msg["provider"].as_str().filter(|s| !trim(s).is_empty()));
        out.push(r);
    }
    Ok(out)
}
