use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::Value;
use std::path::Path;

pub(super) fn parse(
    _identity: &str,
    file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let summary = file.parent().unwrap().join("summary.json");
    let mut model = None;
    if summary.exists() {
        match std::fs::read(summary)
            .map_err(super::Error::from)
            .and_then(|b| json(&b))
        {
            Ok(v) => {
                if jscompat::truthy(&v["current_model_id"]) {
                    model = optional(&v["current_model_id"]);
                }
            }
            Err(_) => note(notes, "bad_lines"),
        }
    }
    let mut out = Vec::new();
    let mut ordinal = 0;
    for (obj, _) in lines(bytes, notes) {
        let p = &obj["params"];
        let u = &p["update"];
        if u["sessionUpdate"] != "turn_completed" || !jscompat::truthy(&u["usage"]) {
            continue;
        }
        let u0 = &u["usage"];
        let tokens = [
            token_of(u0, &["inputTokens", "input_tokens"], notes),
            token_of(u0, &["outputTokens", "output_tokens"], notes),
            token_of(
                u0,
                &[
                    "cachedReadTokens",
                    "cacheReadInputTokens",
                    "cache_read_input_tokens",
                ],
                notes,
            ),
            token_of(
                u0,
                &[
                    "cachedWriteTokens",
                    "cacheCreationTokens",
                    "cache_creation_input_tokens",
                ],
                notes,
            ),
        ];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let session = optional(fallback(&[&p["sessionId"]])).unwrap_or_default();
        let time = jscompat::normalize_timestamp(
            fallback(&[&obj["timestamp"], &p["_meta"]["agentTimestampMs"]]),
            zone,
        );
        let id = nullish(&[&u["turnId"], &u["id"], &p["turnId"]]);
        let key = if jscompat::truthy(id) {
            jscompat::string(id)
        } else {
            format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
        };
        out.push(event(
            "grok",
            format!("grok|{session}|{key}"),
            session,
            model.clone(),
            time,
            tokens,
        ));
    }
    Ok(out)
}
