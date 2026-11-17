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
    timing_ref: Option<String>,
    timing_ambiguous: bool,
    timing_end: Option<i64>,
    timing_completed: bool,
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
    let mut requests: HashMap<String, Vec<Option<i64>>> = HashMap::new();
    for (object, line) in lines(bytes, notes) {
        if !object.is_object() && !object.is_array() {
            continue;
        }
        if cwd.is_none() {
            cwd = project(&object["cwd"]);
        }
        if object["type"] == "api-request" {
            if let Some(id) = object["id"].as_str().filter(|s| !s.is_empty()) {
                requests
                    .entry(id.into())
                    .or_default()
                    .push(super::timing::timestamp(&object["timestamp"], zone));
            }
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
        let timing_ref = object["requestRef"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let timing_end = super::timing::timestamp(&object["timestamp"], zone);
        let timing_completed = object["message"]["stop_reason"]
            .as_str()
            .is_some_and(|reason| !trim(reason).is_empty());
        if let Some(index) = id.as_ref().and_then(|id| indexes.get(id)).copied() {
            let entry: &mut ClaudeEntry = &mut entries[index];
            entry.timing_ambiguous |= timing_ref.is_none() || timing_ref != entry.timing_ref;
            entry.timing_end = timing_end;
            entry.timing_completed = timing_completed;
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
                timing_ref,
                timing_ambiguous: false,
                timing_end,
                timing_completed,
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
    let mut messages_per_request = HashMap::<String, usize>::new();
    for entry in entries.iter().chain(&orphans) {
        if let Some(reference) = &entry.timing_ref {
            *messages_per_request.entry(reference.clone()).or_default() += 1;
        }
    }
    for entry in entries.into_iter().chain(orphans) {
        let duration = if entry.timing_ambiguous
            || entry.id.is_none()
            || entry
                .timing_ref
                .as_ref()
                .is_some_and(|reference| messages_per_request.get(reference) != Some(&1))
        {
            None
        } else {
            entry
                .timing_ref
                .as_ref()
                .and_then(|id| requests.get(id))
                .filter(|starts| starts.len() == 1)
                .and_then(|starts| super::timing::difference(entry.timing_end, starts[0]))
        };
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
        record["timing"] = super::timing::duration(
            duration,
            "log_timestamps",
            if entry.timing_completed {
                "completed"
            } else {
                "partial"
            },
            &record["output_tokens"],
        );
        output.push(record);
    }
    output
}
