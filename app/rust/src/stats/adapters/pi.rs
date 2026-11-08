use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

use super::project::project;
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let name = basename(identity)
        .strip_suffix(".jsonl")
        .unwrap_or(basename(identity));
    let mut session = name.rsplit('_').next().unwrap_or(name).to_owned();
    let mut model = None;
    let mut provider = None;
    let mut cwd = None;
    let mut out = Vec::new();
    let mut ordinal = 0;
    let mut ignored = json!({});
    for (obj, line) in lines(bytes, &mut ignored) {
        if !obj.is_object() && !obj.is_array() {
            continue;
        }
        if obj["type"] == "session" {
            if jscompat::truthy(&obj["id"]) {
                session = jscompat::string(&obj["id"]);
            }
            cwd = project(&obj["cwd"]);
        }
        if obj["type"] == "model_change"
            && jscompat::truthy(fallback(&[&obj["modelId"], &obj["model"]]))
        {
            model = optional(fallback(&[&obj["modelId"], &obj["model"]]));
            provider = obj["provider"]
                .as_str()
                .filter(|s| !trim(s).is_empty())
                .map(str::to_owned);
        }
        let msg = &obj["message"];
        let u = &msg["usage"];
        if obj["type"] != "message" || msg["role"] != "assistant" || !jscompat::truthy(u) {
            continue;
        }
        let tokens = [
            token_of(u, &["input", "prompt_tokens"], notes),
            token_of(u, &["output", "completion_tokens"], notes),
            token_of(u, &["cacheRead", "cache_read_input_tokens"], notes),
            token_of(u, &["cacheWrite", "cache_creation_input_tokens"], notes),
        ];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let id = if jscompat::truthy(&obj["id"]) {
            jscompat::string(&obj["id"])
        } else {
            format!("{}:{line}", file_tag(identity))
        };
        let raw_provider = if !msg["provider"].is_null() {
            msg["provider"]
                .as_str()
                .filter(|s| !trim(s).is_empty())
                .map(str::to_owned)
        } else if jscompat::truthy(&msg["model"]) {
            None
        } else {
            provider.clone()
        };
        let mut r = event(
            "pi",
            format!("pi|{session}|{id}"),
            session.clone(),
            optional(fallback(&[&msg["model"]])).or_else(|| model.clone()),
            jscompat::normalize_timestamp(fallback(&[&obj["timestamp"], &msg["timestamp"]]), zone),
            tokens,
        );
        r["provider"] = json!(raw_provider);
        r["project_key"] = json!(cwd);
        if !jscompat::truthy(&obj["id"]) {
            r["replaces"] = json!([format!("pi|{session}|#{ordinal}")]);
        }
        out.push(r);
    }
    Ok(out)
}
