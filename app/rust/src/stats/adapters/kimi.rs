use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

fn tokens(u: &Value, notes: &mut Value) -> [Option<i64>; 4] {
    [
        token_of(u, &["prompt_tokens", "input_tokens", "input"], notes),
        token_of(u, &["completion_tokens", "output_tokens", "output"], notes),
        token_of(
            u,
            &[
                "cached_tokens",
                "cache_read_tokens",
                "cacheRead",
                "cachedTokens",
            ],
            notes,
        ),
        token_of(
            u,
            &[
                "cache_write_tokens",
                "cacheWrite",
                "cache_creation_input_tokens",
            ],
            notes,
        ),
    ]
}
fn wire_session(identity: &str) -> Option<String> {
    let parts = identity.split(['/', '\\']).collect::<Vec<_>>();
    let n = parts.len();
    if n >= 6
        && parts[n - 6].eq_ignore_ascii_case("sessions")
        && parts[n - 4]
            .get(..8)
            .is_some_and(|s| s.eq_ignore_ascii_case("session_"))
        && parts[n - 3].eq_ignore_ascii_case("agents")
        && parts[n - 1].eq_ignore_ascii_case("wire.jsonl")
    {
        let id = &parts[n - 4][8..];
        if !id.is_empty() {
            return Some(id.into());
        }
    }
    None
}
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let name = basename(identity);
    let default = name.rsplit_once('.').map_or(name, |(s, _)| s);
    let default = if default.is_empty() {
        "kimi-session"
    } else {
        default
    };
    let mut out = Vec::new();
    let mut ordinal = 0;
    if identity.ends_with(".json") {
        let data = json(bytes)?;
        if !data.is_object() && !data.is_array() {
            return Ok(out);
        }
        let session = optional(nullish(&[
            &data["session_id"],
            &data["sessionId"],
            &data["id"],
        ]))
        .unwrap_or_else(|| default.into());
        let rows = data
            .as_array()
            .or_else(|| data["messages"].as_array())
            .or_else(|| data["rounds"].as_array())
            .cloned()
            .unwrap_or_else(|| vec![data.clone()]);
        for item in rows {
            if !item.is_object() && !item.is_array() {
                continue;
            }
            let role = &item["role"];
            if jscompat::truthy(role) && role != "assistant" && role != "model" && role != "bot" {
                continue;
            }
            let u = fallback(&[&item["usage"], &item["token_usage"], &item]);
            let tokens = tokens(u, notes);
            if empty(&tokens, notes) {
                continue;
            }
            ordinal += 1;
            let time = jscompat::normalize_timestamp(
                nullish(&[
                    &item["timestamp"],
                    &item["created_at"],
                    &item["time"],
                    &data["created_at"],
                    &data["timestamp"],
                ]),
                zone,
            );
            let id = nullish(&[&item["id"], &item["message_id"]]);
            let key = if jscompat::truthy(id) {
                jscompat::string(id)
            } else {
                format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
            };
            out.push(event(
                "kimi",
                format!("kimi|{session}|{key}"),
                session.clone(),
                optional(nullish(&[&item["model"], &data["model"]])),
                time,
                tokens,
            ));
        }
    } else {
        let wire = wire_session(identity);
        for (row, line) in lines(bytes, notes) {
            if !row.is_object() && !row.is_array() {
                continue;
            }
            if row["type"] == "usage.record" {
                let u = &row["usage"];
                if !u.is_object() && !u.is_array() {
                    continue;
                }
                let tokens = [
                    token_of(u, &["inputOther"], notes),
                    token_of(u, &["output"], notes),
                    token_of(u, &["inputCacheRead"], notes),
                    token_of(u, &["inputCacheCreation"], notes),
                ];
                if empty(&tokens, notes) {
                    continue;
                }
                let session = wire.clone().unwrap_or_else(|| default.into());
                let time = jscompat::normalize_timestamp(&row["time"], zone);
                let mut r = event(
                    "kimi",
                    format!(
                        "kimi|{session}|{}:{}:{line}",
                        file_tag(identity),
                        time.as_deref().unwrap_or("null")
                    ),
                    session.clone(),
                    optional(&row["model"]),
                    time,
                    tokens,
                );
                r["session_id"] = json!(session);
                out.push(r);
                continue;
            }
            if wire.is_some() {
                continue;
            }
            let msg = fallback(&[&row["message"], &row]);
            let u = fallback(&[&msg["usage"], &row["usage"], &row["token_usage"]]);
            if !u.is_object() && !u.is_array() {
                continue;
            }
            let role = fallback(&[&msg["role"], &row["role"]]);
            if jscompat::truthy(role) && role != "assistant" && role != "model" && role != "bot" {
                continue;
            }
            let tokens = tokens(u, notes);
            if empty(&tokens, notes) {
                continue;
            }
            ordinal += 1;
            let session = optional(nullish(&[
                &row["session_id"],
                &row["sessionId"],
                &row["id"],
            ]))
            .unwrap_or_else(|| default.into());
            let time = jscompat::normalize_timestamp(
                nullish(&[&row["timestamp"], &row["created_at"], &row["time"]]),
                zone,
            );
            let id = nullish(&[&row["id"], &row["message_id"]]);
            let key = if jscompat::truthy(id) {
                jscompat::string(id)
            } else {
                format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
            };
            out.push(event(
                "kimi",
                format!("kimi|{session}|{key}"),
                session,
                optional(nullish(&[&msg["model"], &row["model"]])),
                time,
                tokens,
            ));
        }
    }
    Ok(out)
}
