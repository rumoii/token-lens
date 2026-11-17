use super::super::{
    jscompat::{self, LocalZone},
    Error, Result,
};
use super::{lines::*, num::*, project::*, timing};
use serde_json::{json, Value};
use std::collections::HashMap;
#[cfg(test)]
#[path = "codex_tests.rs"]
mod tests;

pub(super) fn parse(
    identity: &str,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let mut session = None;
    let mut cwd = None;
    let mut model = None;
    let mut provider = None;
    let mut ordinal = 0;
    let mut output = Vec::new();
    let mut occurrences = HashMap::new();
    let mut request_start = None;
    let mut first_output: Option<i64> = None;
    let mut output_lower_bound: Option<i64> = None;
    let tag = file_tag(identity.strip_suffix(".zst").unwrap_or(identity));
    for (object, line) in lines(bytes, notes) {
        let payload = if jscompat::truthy(&object["payload"]) {
            &object["payload"]
        } else {
            &object
        };
        if payload.is_null() {
            return Err(Error(
                "Cannot read properties of null (reading 'session_id')".into(),
            ));
        }
        let time_ms = || {
            jscompat::normalize_timestamp(&object["timestamp"], zone)
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
                .map(|t| t.timestamp_millis())
        };
        let event = object["type"] == "event_msg";
        let boundary = (event
            && (matches!(
                payload["type"].as_str(),
                Some("task_started" | "turn_started")
            ) || (payload["type"] == "item_completed"
                && payload["item"]["type"] == "UserMessage")))
            || (object["type"] == "response_item"
                && ((payload["type"] == "message" && payload["role"] == "user")
                    || matches!(
                        payload["type"].as_str(),
                        Some("function_call_output" | "custom_tool_call_output")
                    )));
        let aborted = event && payload["type"] == "turn_aborted";
        // Undated, stale or repeated boundaries cannot erase confirmed output.
        // An abort at the current lower bound still explicitly clears the window.
        if (boundary || aborted)
            && time_ms().is_none_or(|time| {
                output_lower_bound.is_some_and(|bound| {
                    time < bound || (time == bound && !aborted && first_output.is_some())
                })
            })
        {
            continue;
        }
        if object["type"] == "session_meta" {
            provider = payload["model_provider"]
                .as_str()
                .filter(|s| !trim(s).is_empty())
                .map(str::to_owned);
        }
        if jscompat::truthy(&payload["session_id"]) {
            session = Some(jscompat::string(&payload["session_id"]));
        }
        if cwd.is_none() {
            cwd = project(&payload["cwd"]).or_else(|| project(&payload["working_directory"]));
        }
        if let Some(next) = payload["model"].as_str().filter(|s| !s.is_empty()) {
            model = Some(next.to_owned());
        }
        if boundary || aborted || object["type"] == "token_usage_record" {
            if let Some(time) = time_ms() {
                output_lower_bound = Some(output_lower_bound.map_or(time, |old| old.max(time)));
            }
        }
        if boundary || aborted {
            request_start = if aborted { None } else { time_ms() };
            first_output = None;
        }
        if event
            && payload["type"] == "item_completed"
            && matches!(
                payload["item"]["type"].as_str(),
                Some("Reasoning" | "AgentMessage")
            )
        {
            if let (Some(start), Some(end)) = (
                timing::milliseconds(&payload["started_at_ms"]),
                timing::milliseconds(&payload["completed_at_ms"]),
            ) {
                // Instantaneous completions expose no first output. Older items belong
                // to a consumed or interrupted request even when its usage never arrived.
                if end > start && output_lower_bound.is_none_or(|bound| start >= bound) {
                    first_output = Some(first_output.map_or(start, |old| old.min(start)));
                }
            }
        }
        if object["type"] != "token_usage_record" {
            continue;
        }
        // Consume the window even for invalid/zero usage; it belongs to exactly one request.
        let ttft = timing::difference(first_output, request_start.take());
        let generation = timing::difference(time_ms(), first_output.take());
        let usage = &payload["usage"];
        if !usage.is_object() && !usage.is_array() {
            continue;
        }
        let read = token_of(
            usage,
            &[
                "cached_input_tokens",
                "cache_read_input_tokens",
                "cache_read_tokens",
            ],
            notes,
        );
        let input = minus(
            token_of(usage, &["input_tokens", "prompt_tokens"], notes),
            read,
        );
        let out = token_of(usage, &["output_tokens", "completion_tokens"], notes);
        if [input, out, read].iter().all(|n| n.unwrap_or(0) == 0) {
            note(notes, "zero_usage");
            continue;
        }
        ordinal += 1;
        let record_model = usage["model"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| model.clone());
        let raw_time = if jscompat::truthy(&object["timestamp"]) {
            &object["timestamp"]
        } else {
            &payload["timestamp"]
        };
        let time = jscompat::normalize_timestamp(raw_time, zone);
        let response = &payload["response_id"];
        // Shape-only classification gives a partial history copy the same identity as its original.
        // Normal suffixes observed locally and in evidence are 35/48/50 characters.
        let bad_id = jscompat::truthy(response) && {
            let id = jscompat::string(response);
            let suffix = id.strip_prefix("resp_").unwrap_or(&id);
            suffix.chars().count() < 16 || suffix.bytes().all(|c| c.is_ascii_digit())
        };
        // Rust intentionally differs from Node for unreliable response IDs (specs/stats.md).
        let key = if bad_id {
            if let (Some(thread), Some(timestamp)) = (
                payload["thread_id"].as_str().filter(|s| !s.is_empty()),
                raw_time.as_str().filter(|s| !s.is_empty()),
            ) {
                let base = format!(
                    "codex|{}|{thread}|{timestamp}",
                    session.as_deref().unwrap_or("")
                );
                let count = occurrences.entry(base.clone()).or_insert(0);
                *count += 1;
                if *count == 1 {
                    base
                } else {
                    format!("{base}#{count}")
                }
            } else {
                format!("codex|{}|{tag}:{line}", session.as_deref().unwrap_or(""))
            }
        } else if jscompat::truthy(response) {
            format!(
                "codex|{}|{}",
                session.as_deref().unwrap_or(""),
                jscompat::string(response)
            )
        } else {
            format!("codex|{}|{tag}:{line}", session.as_deref().unwrap_or(""))
        };
        let mut record = json!({"record_key":key,"source":"codex","session_id":session,"project_key":cwd,"model":record_model,"provider":provider,"observed_at":time,"kind":"event","input_tokens":input,"output_tokens":out,"cache_read_tokens":read,"cache_write_tokens":null,"timestamp":time,"cache_creation_tokens":null});
        record["timing"] =
            timing::request(ttft, generation, "log_timestamps", "completed", &json!(out));
        if bad_id {
            record["replaces"] = json!([format!(
                "codex|{}|{}",
                session.as_deref().unwrap_or(""),
                jscompat::string(response)
            )]);
        } else if !jscompat::truthy(response) {
            let old = if jscompat::truthy(&payload["turn_id"]) {
                jscompat::string(&payload["turn_id"])
            } else {
                format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
            };
            record["replaces"] =
                json!([format!("codex|{}|{old}", session.as_deref().unwrap_or(""))]);
        }
        output.push(record);
    }
    Ok(output)
}
