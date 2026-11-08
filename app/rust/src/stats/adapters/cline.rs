use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

fn number(value: &Value) -> f64 {
    match value {
        Value::Null => 0.0,
        Value::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Value::Number(n) => n.as_f64().unwrap(),
        Value::String(s) => {
            if trim(s).is_empty() {
                0.0
            } else {
                s.parse().unwrap_or(f64::NAN)
            }
        }
        _ => f64::NAN,
    }
}
pub(super) fn parse(
    identity: &str,
    file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let messages = json(bytes)?;
    let Some(messages) = messages.as_array().filter(|a| !a.is_empty()) else {
        return Ok(vec![]);
    };
    let side = file.parent().unwrap().join("ui_messages.json");
    let mut timeline = Vec::new();
    if side.exists() {
        let ui = match std::fs::read(side)
            .map_err(super::Error::from)
            .and_then(|b| json(&b))
        {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                Value::Null
            }
        };
        if let Some(ui) = ui.as_array() {
            for m in ui {
                if m.is_null() {
                    return Err(super::Error("null ui message".into()));
                }
                if m["say"] == "api_req_started" && m["text"].is_string() {
                    match json(m["text"].as_str().unwrap().as_bytes()) {
                        Ok(v) => {
                            let model = fallback(&[&v["model"], &v["request"]["model"]]);
                            if jscompat::truthy(model) && jscompat::truthy(&m["ts"]) {
                                timeline.push((number(&m["ts"]), jscompat::string(model)));
                            }
                        }
                        Err(_) => note(notes, "bad_lines"),
                    }
                } else if jscompat::truthy(&m["apiConfiguration"]["model"]) {
                    timeline.insert(0, (0.0, jscompat::string(&m["apiConfiguration"]["model"])));
                }
            }
        }
    }
    timeline.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let session = parent_name(identity).to_owned();
    let mut out = Vec::new();
    let mut ordinal = 0;
    for m in messages {
        if m.is_null() {
            return Err(super::Error("null message".into()));
        }
        let u = &m["usage"];
        if m["role"] != "assistant" || (!u.is_object() && !u.is_array()) {
            continue;
        }
        let tokens = [
            token_of(u, &["input_tokens"], notes),
            token_of(u, &["output_tokens"], notes),
            token_of(u, &["cache_read_input_tokens"], notes),
            token_of(u, &["cache_creation_input_tokens"], notes),
        ];
        if empty(&tokens, notes) {
            continue;
        }
        ordinal += 1;
        let ts = number(fallback(&[&m["ts"], &json!(0)]));
        let model = if jscompat::truthy(&m["model"]) {
            optional(&m["model"])
        } else {
            timeline
                .iter()
                .rev()
                .find(|(t, _)| *t <= ts)
                .or_else(|| timeline.first())
                .map(|(_, m)| m.clone())
        };
        let time = jscompat::normalize_timestamp(&json!(ts), zone);
        let id = nullish(&[&m["id"], &m["messageId"]]);
        let id = if jscompat::truthy(id) {
            jscompat::string(id)
        } else {
            format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
        };
        out.push(event(
            "cline",
            format!("cline|{session}|{id}"),
            session.clone(),
            model,
            time,
            tokens,
        ));
    }
    Ok(out)
}
