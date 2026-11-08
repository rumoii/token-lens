use super::super::jscompat::{self, LocalZone};
use super::{lines::*, num::*, project::*};
use serde_json::{json, Value};
use std::collections::HashMap;
struct ClaudeEntry {
    id: Option<String>,
    uuid: Option<String>,
    line: usize,
    session: String,
    model: Option<String>,
    time: Option<String>,
    usage: [Option<i64>; 4],
    split: [Option<i64>; 2],
}

pub(super) fn parse(
    identity: &str,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Vec<Value> {
    let mut entries: Vec<ClaudeEntry> = Vec::new();
    let mut orphans = Vec::new();
    let mut indexes = HashMap::new();
    let mut cwd = None;
    for (object, line) in lines(bytes, notes) {
        if !object.is_object() && !object.is_array() {
            continue;
        }
        if cwd.is_none() {
            cwd = project(&object["cwd"]);
        }
        let usage = if jscompat::truthy(&object["message"]["usage"]) {
            &object["message"]["usage"]
        } else {
            &object["usage"]
        };
        if !usage.is_object() && !usage.is_array() {
            continue;
        }
        let tokens = [
            token_of(usage, &["input_tokens"], notes),
            token_of(usage, &["output_tokens"], notes),
            token_of(
                usage,
                &["cache_read_input_tokens", "cached_input_tokens"],
                notes,
            ),
            token_of(usage, &["cache_creation_input_tokens"], notes),
        ];
        let mut split = [None, None];
        if usage["cache_creation"].is_object() || usage["cache_creation"].is_array() {
            let a = token(&usage["cache_creation"]["ephemeral_5m_input_tokens"], notes);
            let b = token(&usage["cache_creation"]["ephemeral_1h_input_tokens"], notes);
            if a.is_some() && b.is_some() {
                split = [a, b];
            }
        }
        if tokens.iter().all(|n| n.unwrap_or(0) == 0) {
            note(notes, "zero_usage");
            continue;
        }
        let id = object["message"]["id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| object["id"].as_str().filter(|s| s.starts_with("msg_")))
            .map(str::to_owned);
        let session = if jscompat::truthy(&object["sessionId"]) {
            jscompat::string(&object["sessionId"])
        } else {
            String::new()
        };
        let raw_model = if jscompat::truthy(&object["message"]["model"]) {
            &object["message"]["model"]
        } else {
            &object["model"]
        };
        let model = jscompat::truthy(raw_model).then(|| jscompat::string(raw_model));
        let time = jscompat::normalize_timestamp(&object["timestamp"], zone);
        if let Some(index) = id.as_ref().and_then(|id| indexes.get(id)).copied() {
            let entry: &mut ClaudeEntry = &mut entries[index];
            for (old, new) in entry.usage.iter_mut().zip(tokens) {
                *old = (*old).max(new);
            }
            for (old, new) in entry.split.iter_mut().zip(split) {
                *old = (*old).max(new);
            }
            if entry.model.is_none() {
                entry.model = model;
            }
            if entry.time.is_none() {
                entry.time = time;
            }
        } else {
            let entry = ClaudeEntry {
                id: id.clone(),
                uuid: object["uuid"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned),
                line,
                session,
                model,
                time,
                usage: tokens,
                split,
            };
            if let Some(id) = id {
                indexes.insert(id, entries.len());
                entries.push(entry);
            } else {
                orphans.push(entry);
            }
        }
    }
    let mut output = Vec::new();
    let mut orphan_index = 0;
    for entry in entries.into_iter().chain(orphans) {
        let (key, old) = if let Some(id) = entry.id {
            (
                format!("claude|{id}"),
                format!("claude|{}|{id}", entry.session),
            )
        } else {
            orphan_index += 1;
            (
                format!(
                    "claude|{}",
                    entry
                        .uuid
                        .unwrap_or_else(|| format!("{}:{}", file_tag(identity), entry.line))
                ),
                format!("claude|{}|#{orphan_index}", entry.session),
            )
        };
        let mut record = json!({"record_key":key,"replaces":[old],"source":"claude","session_id":if entry.session.is_empty(){None}else{Some(entry.session)},"project_key":cwd,"model":entry.model,"observed_at":entry.time,"kind":"event","input_tokens":entry.usage[0],"output_tokens":entry.usage[1],"cache_read_tokens":entry.usage[2],"cache_write_tokens":entry.usage[3],"timestamp":entry.time,"cache_creation_tokens":entry.usage[3]});
        if let (Some(a), Some(b)) = (entry.split[0], entry.split[1]) {
            if plus(Some(a), Some(b)) == entry.usage[3] {
                record["cache_write_5m_tokens"] = json!(a);
                record["cache_write_1h_tokens"] = json!(b);
            }
        }
        output.push(record);
    }
    output
}
