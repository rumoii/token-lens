use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

fn usage(raw: &Value, notes: &mut Value) -> Option<[Option<i64>; 4]> {
    if !raw.is_object() && !raw.is_array() {
        return None;
    }
    let prompt = token_of(
        raw,
        &[
            "promptTokenCount",
            "prompt_token_count",
            "inputTokens",
            "input_tokens",
        ],
        notes,
    );
    let out = token_of(
        raw,
        &[
            "candidatesTokenCount",
            "candidates_token_count",
            "outputTokens",
            "output_tokens",
        ],
        notes,
    );
    let read = token_of(
        raw,
        &[
            "cachedContentTokenCount",
            "cached_content_token_count",
            "cachedTokens",
            "cache_read_tokens",
        ],
        notes,
    );
    let write = token_of(
        raw,
        &[
            "cacheWriteTokens",
            "cache_write_tokens",
            "cache_creation_tokens",
        ],
        notes,
    );
    if empty(&[prompt, out, read, write], notes) {
        None
    } else {
        Some([minus(prompt, read), out, read, write])
    }
}
fn model(obj: &Value) -> Result<Option<String>> {
    for key in ["model", "modelId"] {
        if let Some(s) = obj[key].as_str().filter(|s| !s.is_empty()) {
            return Ok(Some(s.into()));
        }
    }
    if let Some(msgs) = obj["messages"].as_array() {
        for msg in msgs {
            if msg.is_null() {
                return Err(super::Error("null message".into()));
            }
            if msg["role"] == "model" {
                if let Some(s) = msg["model"].as_str().filter(|s| !s.is_empty()) {
                    return Ok(Some(s.into()));
                }
            }
        }
    }
    Ok(None)
}
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let name = basename(identity);
    let ext = name
        .rsplit_once('.')
        .map_or(String::new(), |(_, s)| format!(".{}", s.to_lowercase()));
    let name = name.strip_suffix(&ext).unwrap_or(name);
    let default = name.strip_prefix("session-").unwrap_or(name);
    let mut out = Vec::new();
    if ext == ".jsonl" {
        let mut ordinal = 0;
        for (obj, _) in lines(bytes, notes) {
            if !obj.is_object() && !obj.is_array() {
                continue;
            }
            let Some(tokens) = usage(nullish(&[&obj["usageMetadata"], &obj["usage"]]), notes)
            else {
                continue;
            };
            ordinal += 1;
            let session = optional(nullish(&[&obj["id"], &obj["sessionId"]]))
                .unwrap_or_else(|| default.into());
            let time = jscompat::normalize_timestamp(
                nullish(&[&obj["startTime"], &obj["createTime"], &obj["timestamp"]]),
                zone,
            );
            out.push(event(
                "gemini",
                format!(
                    "gemini|{session}|{}|{ordinal}",
                    time.as_deref().unwrap_or("null")
                ),
                session,
                model(&obj)?,
                time,
                tokens,
            ));
        }
    } else {
        let data = json(bytes)?;
        if !data.is_object() && !data.is_array() {
            return Ok(out);
        }
        let session =
            optional(nullish(&[&data["id"], &data["sessionId"]])).unwrap_or_else(|| default.into());
        let sm = model(&data)?;
        if let Some(tokens) = usage(nullish(&[&data["usageMetadata"], &data["usage"]]), notes) {
            let time = jscompat::normalize_timestamp(
                nullish(&[&data["startTime"], &data["createTime"], &data["timestamp"]]),
                zone,
            );
            let mut r = event(
                "gemini",
                format!("gemini|{session}"),
                session,
                sm,
                time,
                tokens,
            );
            r["kind"] = json!("cumulative");
            out.push(r);
        } else if let Some(messages) = data["messages"].as_array() {
            let mut ordinal = 0;
            for msg in messages {
                if !msg.is_object() && !msg.is_array() {
                    continue;
                }
                if msg["role"] != "model" && msg["role"] != "assistant" {
                    continue;
                }
                let Some(tokens) = usage(nullish(&[&msg["usageMetadata"], &msg["usage"]]), notes)
                else {
                    continue;
                };
                ordinal += 1;
                let time = jscompat::normalize_timestamp(
                    nullish(&[&msg["createTime"], &msg["timestamp"], &data["startTime"]]),
                    zone,
                );
                out.push(event(
                    "gemini",
                    format!(
                        "gemini|{session}|{}|{ordinal}",
                        time.as_deref().unwrap_or("null")
                    ),
                    session.clone(),
                    if jscompat::truthy(&msg["model"]) {
                        optional(&msg["model"])
                    } else {
                        sm.clone()
                    },
                    time,
                    tokens,
                ));
            }
        }
    }
    Ok(out)
}
