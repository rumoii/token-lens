use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;
#[derive(Default)]
struct TurnWindow {
    user_seen: bool,
    output_seen: bool,
    start: Option<i64>,
    first: Option<i64>,
}
fn has_text(content: &Value) -> bool {
    content["text"].as_str().is_some_and(|s| !s.is_empty())
        || content.as_array().is_some_and(|a| a.iter().any(has_text))
}

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
    let mut windows = std::collections::HashMap::<String, TurnWindow>::new();
    for (obj, _) in lines(bytes, notes) {
        let p = &obj["params"];
        let u = &p["update"];
        let session_key = p["sessionId"].as_str().filter(|s| !s.is_empty());
        let mut completed = None;
        if let Some(session) = session_key {
            let window = windows.entry(session.into()).or_default();
            let time = super::timing::milliseconds(&p["_meta"]["agentTimestampMs"]);
            match u["sessionUpdate"].as_str() {
                Some("user_message_chunk") if !window.user_seen => {
                    window.user_seen = true;
                    window.start = time;
                }
                Some("agent_message_chunk") if !window.output_seen && has_text(&u["content"]) => {
                    window.output_seen = true;
                    window.first = time;
                }
                Some("turn_completed") => {
                    completed = windows.remove(session);
                }
                Some("turn_cancelled" | "turn_aborted" | "turn_failed") => {
                    windows.remove(session);
                }
                _ => {}
            }
        }
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
        let mut record = event(
            "grok",
            format!("grok|{session}|{key}"),
            session,
            model.clone(),
            time,
            tokens,
        );
        let mut timing = super::timing::duration(
            super::timing::positive_ms(&u0["apiDurationMs"]),
            "client_reported",
            "completed",
            &record["output_tokens"],
        );
        let ttft = completed.and_then(|w| super::timing::difference(w.first, w.start));
        timing["ttft_ms"] = json!(ttft);
        timing["ttft_method"] = json!(ttft.map(|_| "log_timestamps"));
        timing["scope"] = json!("turn");
        record["timing"] = timing;
        out.push(record);
    }
    Ok(out)
}
