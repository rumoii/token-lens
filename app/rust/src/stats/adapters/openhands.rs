use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::Value;
use std::path::Path;

use super::super::jscompat::{encode_uri_component, JsJson};
use std::collections::HashMap;
pub(in crate::stats) fn event_name(name: &str) -> bool {
    let Some(s) = name
        .strip_prefix("event-")
        .and_then(|s| s.strip_suffix(".json"))
    else {
        return false;
    };
    let Some((digits, id)) = s.split_once('-') else {
        return false;
    };
    digits.len() >= 5
        && digits.bytes().all(|b| b.is_ascii_digit())
        && id.len() >= 8
        && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}
pub(super) fn parse(
    _identity: &str,
    file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let raw = JsJson::parse(&String::from_utf8_lossy(bytes)).map_err(super::Error)?;
    let state = raw.to_value();
    let Some(session) = state["id"].as_str().filter(|s| !trim(s).is_empty()) else {
        note(notes, "bad_fields");
        return Ok(vec![]);
    };
    if state["agent"]["kind"] != "Agent" {
        return Ok(vec![]);
    }
    let JsJson::Object(metrics) = raw.get("stats").get("usage_to_metrics") else {
        note(notes, "bad_fields");
        return Ok(vec![]);
    };
    let mut times: HashMap<String, String> = HashMap::new();
    let events = super::openhands_events(file);
    match std::fs::read_dir(events) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
        Ok(entries) => {
            let mut entries = entries.collect::<std::io::Result<Vec<_>>>()?;
            entries.sort_by_key(|e| e.file_name());
            for entry in entries {
                if !event_name(&entry.file_name().to_string_lossy()) {
                    continue;
                }
                let bytes = std::fs::read(entry.path())?;
                let v = match json(&bytes) {
                    Ok(v) if v.is_object() => v,
                    _ => {
                        note(notes, "bad_lines");
                        continue;
                    }
                };
                let Some(id) = v["llm_response_id"]
                    .as_str()
                    .filter(|s| !trim(s).is_empty())
                else {
                    continue;
                };
                let Some(time) = v["timestamp"]
                    .as_str()
                    .and_then(|_| jscompat::normalize_timestamp(&v["timestamp"], zone))
                else {
                    continue;
                };
                if times.get(id).is_none_or(|old| time < *old) {
                    times.insert(id.into(), time);
                }
            }
        }
    }
    let mut out = Vec::new();
    for (usage_units, metric_raw) in metrics {
        let usage_id = String::from_utf16_lossy(usage_units);
        let missing = if ["task:", "delegate:", "agent-hook:"]
            .iter()
            .any(|p| usage_id.starts_with(p))
        {
            "subagent_copies"
        } else {
            "bad_times"
        };
        let metric = metric_raw.to_value();
        if !metric.is_object() {
            note(notes, "bad_fields");
            continue;
        }
        if metric.get("token_usages").is_none() {
            continue;
        }
        let JsJson::Array(usages) = metric_raw.get("token_usages") else {
            note(notes, "bad_fields");
            continue;
        };
        let mut seen = HashMap::new();
        for usage_raw in usages {
            let u = usage_raw.to_value();
            if !u.is_object() {
                note(notes, "bad_fields");
                continue;
            }
            let Some(id) = u["response_id"].as_str().filter(|s| !trim(s).is_empty()) else {
                note(notes, missing);
                continue;
            };
            let occurrence = seen.entry(id.to_owned()).or_insert(0);
            *occurrence += 1;
            if *occurrence > 1 {
                note(notes, "duplicate_response_ids");
            }
            let Some(time) = times.get(id) else {
                note(notes, missing);
                continue;
            };
            let prompt = token(&u["prompt_tokens"], notes);
            let output = token(&u["completion_tokens"], notes);
            let read = token(&u["cache_read_tokens"], notes);
            let write = token(&u["cache_write_tokens"], notes);
            let input = prompt.zip(read).zip(write).and_then(|((p, r), w)| {
                if p - r - w < 0 {
                    note(notes, "bad_fields");
                    None
                } else {
                    Some(p - r - w)
                }
            });
            let tokens = [input, output, read, write];
            if empty(&tokens, notes) {
                continue;
            }
            let JsJson::String(session_units) = raw.get("id") else {
                unreachable!()
            };
            let JsJson::String(id_units) = usage_raw.get("response_id") else {
                unreachable!()
            };
            let identity = [
                session_units.as_slice(),
                usage_units.as_slice(),
                id_units.as_slice(),
            ]
            .into_iter()
            .map(encode_uri_component)
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(super::Error)?
            .join("|");
            let model = u["model"]
                .as_str()
                .map(trim)
                .filter(|s| {
                    !s.is_empty()
                        && !s.eq_ignore_ascii_case("default")
                        && !s.eq_ignore_ascii_case("unknown")
                })
                .map(str::to_owned);
            let mut r = event(
                "openhands",
                format!(
                    "openhands|{identity}{}",
                    if *occurrence > 1 {
                        format!("#{occurrence}")
                    } else {
                        String::new()
                    }
                ),
                session.into(),
                model,
                Some(time.clone()),
                tokens,
            );
            r.as_object_mut().unwrap().remove("timestamp");
            r.as_object_mut().unwrap().remove("cache_creation_tokens");
            let latencies: Vec<_> = metric["response_latencies"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|l| l["response_id"] == id)
                .collect();
            let unique_usage = usages
                .iter()
                .filter(|u| u.to_value()["response_id"] == id)
                .count()
                == 1;
            let duration = if unique_usage && latencies.len() == 1 {
                super::timing::seconds(&latencies[0]["latency"])
            } else {
                None
            };
            r["timing"] = super::timing::duration(
                duration,
                "client_reported",
                "completed",
                &r["output_tokens"],
            );
            out.push(r);
        }
    }
    Ok(out)
}
