mod zstd;

use super::{
    jscompat::{self, LocalZone},
    Error, Result,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;

fn trim(text: &str) -> &str {
    text.trim_matches(|c:char| matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}'))
}
fn note(notes: &mut Value, key: &str) {
    notes[key] = json!(notes[key].as_i64().unwrap_or(0) + 1);
}

pub fn file_tag(identity: &str) -> String {
    format!(
        "f{}",
        &format!("{:x}", Sha256::digest(identity.as_bytes()))[..12]
    )
}

fn token(value: &Value, notes: &mut Value) -> Option<i64> {
    if value.is_null() {
        return None;
    }
    let result = if let Some(n) = value.as_f64().filter(|_| value.is_number()) {
        (n >= 0.0 && n.fract() == 0.0 && n <= 9007199254740991.0).then_some(n as i64)
    } else if let Some(s) = value
        .as_str()
        .map(trim)
        .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
    {
        s.parse::<i64>().ok().filter(|n| *n <= 9007199254740991)
    } else {
        None
    };
    if result.is_none() {
        note(notes, "bad_fields");
    }
    result
}

fn token_of(object: &Value, keys: &[&str], notes: &mut Value) -> Option<i64> {
    for key in keys {
        if !object[*key].is_null() {
            return token(&object[*key], notes);
        }
    }
    None
}

pub fn minus(total: Option<i64>, part: Option<i64>) -> Option<i64> {
    total.map(|n| (n - part.unwrap_or(0)).max(0))
}
pub fn plus(a: Option<i64>, b: Option<i64>) -> Option<i64> {
    if a.is_none() && b.is_none() {
        None
    } else {
        Some(a.unwrap_or(0) + b.unwrap_or(0))
    }
}

fn project(value: &Value) -> Option<String> {
    let text = trim(value.as_str()?);
    if text.is_empty() {
        return None;
    }
    let bytes = text.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'/' | b'\\')
    {
        Some(text.replace('/', "\\").trim_end_matches('\\').into())
    } else {
        Some(
            if text.trim_end_matches('/').is_empty() {
                "/"
            } else {
                text.trim_end_matches('/')
            }
            .into(),
        )
    }
}

fn lines(bytes: &[u8], notes: &mut Value) -> Vec<(Value, usize)> {
    let text = String::from_utf8_lossy(bytes)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    text.split('\n')
        .enumerate()
        .filter_map(|(index, line)| {
            let line = trim(line);
            if line.is_empty() {
                return None;
            }
            match serde_json::from_str(line) {
                Ok(value) => Some((value, index + 1)),
                Err(_) => {
                    note(notes, "bad_lines");
                    None
                }
            }
        })
        .collect()
}

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

fn claude(identity: &str, bytes: &[u8], zone: &LocalZone, notes: &mut Value) -> Vec<Value> {
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

fn codex(identity: &str, bytes: &[u8], zone: &LocalZone, notes: &mut Value) -> Result<Vec<Value>> {
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

pub fn parse(
    source: &str,
    identity: &str,
    file: &Path,
    zone: &LocalZone,
) -> Result<(Vec<Value>, Value)> {
    let mut notes = json!({"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0});
    let mut bytes = std::fs::read(file)?;
    if source == "codex" && identity.ends_with(".zst") {
        bytes = zstd::decode(&bytes)?;
    }
    let records = match source {
        "claude" => claude(identity, &bytes, zone, &mut notes),
        "codex" => codex(identity, &bytes, zone, &mut notes)?,
        _ => return Err(Error(format!("unknown source: {source}"))),
    };
    Ok((records, notes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adapters_match_node() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        for line in include_str!("../../../tests/golden/adapters.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "adapter_record" {
                let file = row["file"].as_str().unwrap();
                let (records, notes) = parse(
                    row["source"].as_str().unwrap(),
                    file,
                    &root.join(file),
                    &LocalZone::Fixed(480),
                )
                .unwrap();
                assert_eq!(json!(records), row["records"], "{file}");
                assert_eq!(notes, row["notes"], "{file}");
            }
            if row["type"] == "identity" {
                if let Some(file) = row["file"].as_str() {
                    assert_eq!(
                        file_tag(file.strip_suffix(".zst").unwrap_or(file)),
                        row["expected"].as_str().unwrap()
                    );
                } else {
                    assert_eq!(
                        super::super::ledger::payload_hash(&row["record"]),
                        row["expected"].as_str().unwrap()
                    );
                    assert_eq!(
                        super::super::ledger::payload_input(&row["record"])
                            .as_bytes()
                            .iter()
                            .map(|b| format!("{b:02x}"))
                            .collect::<String>(),
                        row["canonical_utf8_hex"].as_str().unwrap()
                    );
                }
            }
            if row["fn"] == "zstd" {
                let bytes = std::fs::read(root.join(format!(
                    "test/fixtures/parity/zstd-{}.bin",
                    row["name"].as_str().unwrap()
                )))
                .unwrap();
                let result = zstd::decode(&bytes);
                if let Some(error) = row["error"].as_str() {
                    assert_eq!(result.unwrap_err().0, error);
                } else {
                    assert_eq!(
                        result
                            .unwrap()
                            .iter()
                            .map(|byte| format!("{byte:02x}"))
                            .collect::<String>(),
                        row["expected"].as_str().unwrap()
                    );
                }
            }
        }
        assert_eq!(plus(None, None), None);
        assert_eq!(plus(None, Some(3)), Some(3));
    }
}
