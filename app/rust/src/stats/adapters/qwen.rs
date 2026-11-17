use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    let mut ordinal = 0;
    for (obj, line) in lines(bytes, notes) {
        if !obj.is_object() && !obj.is_array() {
            continue;
        }
        let raw = token_of(
            &obj,
            &["inputTokens", "input_tokens", "prompt_tokens"],
            notes,
        );
        let read = token_of(
            &obj,
            &["cachedTokens", "cached_tokens", "cache_read_tokens"],
            notes,
        );
        let input = if obj.get("inputTokens").is_some() {
            minus(raw, read)
        } else {
            raw
        };
        let raw_out = token_of(
            &obj,
            &["outputTokens", "output_tokens", "completion_tokens"],
            notes,
        );
        let thoughts = token_of(&obj, &["thoughtsTokens", "thoughts_tokens"], notes);
        let total = nullish(&[&obj["totalTokens"], &obj["total_tokens"]]).as_f64();
        let output = match obj["authType"].as_str() {
            Some("openai" | "openai-responses" | "qwen-oauth" | "anthropic") => {
                if thoughts.unwrap_or(0) > 0 && raw_out.is_none_or(|v| v < thoughts.unwrap()) {
                    note(notes, "bad_fields");
                }
                raw_out.or(thoughts.filter(|v| *v > 0))
            }
            Some("gemini" | "vertex-ai") => plus(raw_out, thoughts),
            _ => {
                if raw.is_some()
                    && raw_out.is_some()
                    && total.is_some_and(|t| {
                        t > 0.0
                            && t <= 9007199254740991.0
                            && t.fract() == 0.0
                            && t == (raw.unwrap() + raw_out.unwrap()) as f64
                    })
                {
                    raw_out
                } else {
                    plus(raw_out, thoughts)
                }
            }
        };
        let write = token_of(
            &obj,
            &[
                "cacheWriteTokens",
                "cache_write_tokens",
                "cache_creation_tokens",
            ],
            notes,
        );
        let tokens = [input, output, read, write];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let session = jscompat::string(nullish(&[
            &obj["sessionId"],
            &obj["session_id"],
            &json!(""),
        ]));
        let id = if jscompat::truthy(&obj["id"]) {
            jscompat::string(&obj["id"])
        } else {
            format!("{}:{line}", file_tag(identity))
        };
        let mut r = event(
            "qwen",
            format!("qwen|{session}|{id}"),
            session.clone(),
            optional(nullish(&[&obj["model"], &obj["model_name"]])),
            jscompat::normalize_timestamp(nullish(&[&obj["timestamp"], &obj["created_at"]]), zone),
            tokens,
        );
        if !jscompat::truthy(&obj["id"]) {
            r["replaces"] = json!([format!("qwen|{session}|#{ordinal}")]);
        }
        r["timing"] = super::timing::duration(
            super::timing::positive_ms(&obj["apiDurationMs"]),
            "client_reported",
            "completed",
            &r["output_tokens"],
        );
        out.push(r);
    }
    Ok(out)
}
