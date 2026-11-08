use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

fn usage(round: &Value, notes: &mut Value) -> Option<[Option<i64>; 4]> {
    let mut input = token_of(
        round,
        &["promptTokens", "inputTokens", "input_tokens"],
        notes,
    );
    let mut output = token_of(
        round,
        &["completionTokens", "outputTokens", "output_tokens"],
        notes,
    );
    let mut read = token_of(round, &["cachedTokens", "cache_read_input_tokens"], notes);
    let u = fallback(&[&round["usage"], &round["message"]["usage"]]);
    if u.is_object() || u.is_array() {
        if input.is_none() {
            input = token_of(u, &["prompt_tokens", "promptTokens", "input_tokens"], notes);
        }
        if output.is_none() {
            output = token_of(
                u,
                &["completion_tokens", "completionTokens", "output_tokens"],
                notes,
            );
        }
        if read.is_none() {
            read = token_of(u, &["cache_read_input_tokens", "cached_tokens"], notes);
        }
    }
    let tc = fallback(&[&round["tokenCount"], &round["message"]["tokenCount"]]);
    if tc.is_object() || tc.is_array() {
        if input.is_none() {
            input = token_of(tc, &["input", "prompt"], notes);
        }
        if output.is_none() {
            output = token_of(tc, &["output", "completion"], notes);
        }
    }
    let tokens = [input, output, read, None];
    (!empty(&tokens, notes)).then_some(tokens)
}
fn model(round: &Value, session: &Option<String>) -> Option<String> {
    for k in ["modelTitle", "model"] {
        if let Some(m) = round[k].as_str().filter(|s| !s.is_empty()) {
            return Some(m.into());
        }
    }
    if let Some(m) = round["selectedModel"]["title"].as_str() {
        return Some(m.into());
    }
    if let Some(m) = round["message"]["model"].as_str() {
        return Some(m.into());
    }
    session.clone().filter(|s| !s.is_empty())
}
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let data = json(bytes)?;
    if !data.is_object() && !data.is_array() {
        return Ok(vec![]);
    }
    let default = basename(identity)
        .strip_suffix(".json")
        .unwrap_or(basename(identity));
    let session =
        optional(fallback(&[&data["sessionId"], &data["id"]])).unwrap_or_else(|| default.into());
    let sm = data["modelTitle"].as_str().map(str::to_owned);
    let default_time =
        jscompat::normalize_timestamp(fallback(&[&data["dateCreated"], &data["timestamp"]]), zone);
    let history = data["history"]
        .as_array()
        .or_else(|| data["messages"].as_array());
    let mut out = Vec::new();
    let mut ordinal = 0;
    if let Some(history) = history {
        for round in history {
            if !round.is_object() && !round.is_array() {
                continue;
            }
            let role = fallback(&[&round["role"], &round["message"]["role"]]);
            if jscompat::truthy(role) && role != "assistant" && role != "model" {
                continue;
            }
            let Some(tokens) = usage(round, notes) else {
                continue;
            };
            ordinal += 1;
            let raw = nullish(&[&round["timestamp"], &round["dateCreated"], &round["time"]]);
            let time = if jscompat::truthy(raw) {
                jscompat::normalize_timestamp(raw, zone)
            } else {
                default_time.clone()
            };
            let id = nullish(&[&round["messageId"], &round["id"]]);
            let id = if jscompat::truthy(id) {
                jscompat::string(id)
            } else {
                format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
            };
            out.push(event(
                "continue",
                format!("continue|{session}|{id}"),
                session.clone(),
                model(round, &sm),
                time,
                tokens,
            ));
        }
    }
    if out.is_empty() && (data["tokenCount"].is_object() || data["tokenCount"].is_array()) {
        let tokens = [
            token_of(&data["tokenCount"], &["input", "prompt"], notes),
            token_of(&data["tokenCount"], &["output", "completion"], notes),
            None,
            None,
        ];
        if !empty(&tokens, notes) {
            let mut r = event(
                "continue",
                format!("continue|{session}"),
                session,
                sm.filter(|s| !s.is_empty()),
                default_time,
                tokens,
            );
            r["kind"] = json!("cumulative");
            out.push(r);
        }
    }
    Ok(out)
}
