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
        if !obj.is_object() {
            continue;
        }
        let u = nullish(&[
            &obj["usage"],
            &obj["response"]["usage"],
            &obj["choices"].get(0).unwrap_or(&Value::Null)["usage"],
        ]);
        if !jscompat::truthy(u) {
            continue;
        }
        let openai = !u["prompt_tokens"].is_null();
        let raw = token_of(
            u,
            &[if openai {
                "prompt_tokens"
            } else {
                "input_tokens"
            }],
            notes,
        );
        let read = if !u["cache_read_input_tokens"].is_null() {
            token_of(u, &["cache_read_input_tokens"], notes)
        } else if !u["prompt_tokens_details"]["cached_tokens"].is_null() {
            token_of(&u["prompt_tokens_details"], &["cached_tokens"], notes)
        } else {
            token_of(u, &["cached_tokens", "cache_read"], notes)
        };
        let write = if !u["cache_creation_input_tokens"].is_null() {
            token_of(u, &["cache_creation_input_tokens"], notes)
        } else {
            token_of(
                &u["prompt_tokens_details"],
                &["cache_creation_tokens"],
                notes,
            )
        };
        let tokens = [
            if openai { minus(raw, read) } else { raw },
            token_of(u, &["completion_tokens", "output_tokens"], notes),
            read,
            write,
        ];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let session = optional(nullish(&[&obj["session_id"], &obj["aider_session_id"]]))
            .unwrap_or_else(|| {
                let p = parent_name(identity);
                if p.is_empty() {
                    "aider-session".into()
                } else {
                    p.into()
                }
            });
        let time = jscompat::normalize_timestamp(
            nullish(&[
                &obj["timestamp"],
                &obj["created"],
                &obj["response"]["created"],
            ]),
            zone,
        );
        let old = if jscompat::truthy(&obj["commit_hash"]) {
            jscompat::string(&obj["commit_hash"])
        } else {
            format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
        };
        let mut r = event(
            "aider",
            format!("aider|{session}|{}:{line}", file_tag(identity)),
            session.clone(),
            optional(nullish(&[
                &obj["model"],
                &obj["response"]["model"],
                &obj["model_name"],
            ])),
            time,
            tokens,
        );
        r["replaces"] = json!([format!("aider|{session}|{old}")]);
        out.push(r);
    }
    Ok(out)
}
