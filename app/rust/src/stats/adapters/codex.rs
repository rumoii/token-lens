use super::super::{
    jscompat::{self, LocalZone},
    Error, Result,
};
use super::{lines::*, num::*, project::*};
use serde_json::{json, Value};
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
        if object["type"] != "token_usage_record" {
            continue;
        }
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
        let key = if jscompat::truthy(response) {
            format!(
                "codex|{}|{}",
                session.as_deref().unwrap_or(""),
                jscompat::string(response)
            )
        } else {
            format!("codex|{}|{tag}:{line}", session.as_deref().unwrap_or(""))
        };
        let mut record = json!({"record_key":key,"source":"codex","session_id":session,"project_key":cwd,"model":record_model,"provider":provider,"observed_at":time,"kind":"event","input_tokens":input,"output_tokens":out,"cache_read_tokens":read,"cache_write_tokens":null,"timestamp":time,"cache_creation_tokens":null});
        if !jscompat::truthy(response) {
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
