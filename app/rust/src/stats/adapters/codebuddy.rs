use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

use super::project::project;
const READ: &[&str] = &[
    "cache_read_input_tokens",
    "cacheReadInputTokens",
    "prompt_cache_hit_tokens",
    "cached_tokens",
];
const WRITE: &[&str] = &[
    "cache_write_input_tokens",
    "cacheWriteInputTokens",
    "cache_creation_input_tokens",
    "prompt_cache_write_tokens",
];
fn cache(objects: &[&Value], keys: &[&str], notes: &mut Value) -> Option<i64> {
    let mut known = None;
    for object in objects {
        for key in keys {
            let value = token_of(object, &[key], notes);
            if value.is_some_and(|v| v > 0) {
                return value;
            }
            if value == Some(0) {
                known = value;
            }
        }
    }
    known
}
struct Context<'a> {
    session: &'a str,
    identity: String,
    model: &'a Value,
    cwd: &'a Value,
    desktop: bool,
    candidates: Vec<&'a Value>,
    raw: &'a Value,
}
fn record(
    row: &Value,
    u: &Value,
    ctx: Context<'_>,
    zone: &LocalZone,
    notes: &mut Value,
) -> Option<Value> {
    let mut input = token_of(
        u,
        if ctx.desktop {
            &["inputTokens", "input_tokens", "prompt_tokens"]
        } else {
            &["input_tokens", "inputTokens", "prompt_tokens"]
        },
        notes,
    );
    let output = token_of(
        u,
        if ctx.desktop {
            &["outputTokens", "output_tokens", "completion_tokens"]
        } else {
            &["output_tokens", "outputTokens", "completion_tokens"]
        },
        notes,
    );
    let mut details = vec![u, &u["prompt_tokens_details"]];
    if let Some(a) = u["inputTokensDetails"].as_array() {
        details.extend(a);
    }
    let mut readkeys = Vec::new();
    let mut writekeys = Vec::new();
    if ctx.desktop {
        readkeys.push("cacheTokens");
        writekeys.push("cachedWriteTokens");
    }
    readkeys.extend(READ);
    writekeys.extend(WRITE);
    let read = cache(&details, &readkeys, notes);
    let mut candidates = ctx.candidates;
    candidates.push(ctx.raw);
    let write = cache(&candidates, &writekeys, notes);
    let miss = token_of(u, &["prompt_cache_miss_tokens"], notes)
        .or_else(|| token_of(ctx.raw, &["prompt_cache_miss_tokens"], notes));
    if miss.is_some() {
        input = miss;
    } else if let Some(i) = input {
        input = if i - read.unwrap_or(0) < 0 {
            note(notes, "bad_fields");
            None
        } else {
            Some(i - read.unwrap_or(0))
        };
    }
    let tokens = [input, output, read, write];
    if empty(&tokens, notes) {
        return None;
    }
    let raw = nullish(&[
        &row["timestamp"],
        &row["ts"],
        if ctx.desktop {
            &row["startedAt"]
        } else {
            &Value::Null
        },
    ]);
    let time = if let Some(s) = raw
        .as_str()
        .filter(|s| !trim(s).is_empty() && trim(s).bytes().all(|b| b.is_ascii_digit()))
    {
        jscompat::normalize_timestamp(&json!(trim(s).parse::<f64>().unwrap_or(f64::NAN)), zone)
    } else {
        jscompat::normalize_timestamp(raw, zone)
    };
    if time.is_none() {
        note(notes, "bad_times");
        return None;
    }
    let mut r = event(
        "codebuddy",
        format!("codebuddy|{}|{}", ctx.session, ctx.identity),
        ctx.session.into(),
        ctx.model
            .as_str()
            .map(trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
        time,
        tokens,
    );
    r["session_id"] = json!(ctx.session);
    r["project_key"] = json!(project(ctx.cwd));
    r.as_object_mut().unwrap().remove("timestamp");
    Some(r)
}
pub(super) fn parse(
    identity: &str,
    file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    if identity.ends_with(".json") {
        let content = json(bytes)?;
        let Some(requests) = content["requests"].as_array() else {
            return Ok(out);
        };
        let session = parent_name(identity);
        let mut model = Value::Null;
        let metadata = file
            .parent()
            .and_then(Path::parent)
            .unwrap()
            .join("index.json");
        if metadata.exists() {
            match std::fs::read(metadata)
                .map_err(super::Error::from)
                .and_then(|b| json(&b))
            {
                Ok(v) => {
                    if let Some(c) = v["conversations"]
                        .as_array()
                        .and_then(|a| a.iter().find(|v| v["id"] == session))
                    {
                        model =
                            nullish(&[&c["selectedModelId"], &c["modelId"], &c["model"]]).clone();
                    }
                }
                Err(_) => note(notes, "bad_lines"),
            }
        }
        for (index, request) in requests.iter().enumerate() {
            if !jscompat::truthy(&request["usage"]) {
                continue;
            }
            let id = request["id"]
                .as_str()
                .filter(|s| !trim(s).is_empty())
                .map_or_else(|| format!("{}:{index}", file_tag(identity)), str::to_owned);
            if let Some(r) = record(
                request,
                &request["usage"],
                Context {
                    session,
                    identity: id,
                    model: &model,
                    cwd: &Value::Null,
                    desktop: true,
                    candidates: vec![&request["usage"]],
                    raw: &Value::Null,
                },
                zone,
                notes,
            ) {
                out.push(r);
            }
        }
    } else {
        let session = basename(identity)
            .strip_suffix(".jsonl")
            .unwrap_or(basename(identity));
        for (row, line) in lines(bytes, notes) {
            if !row.is_object() && !row.is_array() {
                continue;
            }
            let candidates = vec![
                &row["message"]["usage"],
                &row["providerData"]["usage"],
                &row["usage"],
            ];
            let u = candidates
                .iter()
                .copied()
                .find(|v| {
                    v.as_object().is_some_and(|o| {
                        [
                            "input_tokens",
                            "inputTokens",
                            "prompt_tokens",
                            "prompt_cache_miss_tokens",
                        ]
                        .iter()
                        .any(|k| o.contains_key(*k))
                    })
                })
                .or_else(|| {
                    candidates
                        .iter()
                        .copied()
                        .find(|v| v.is_object() || v.is_array())
                });
            let Some(u) = u else {
                continue;
            };
            if let Some(r) = record(
                &row,
                u,
                Context {
                    session,
                    identity: format!("{}:{line}", file_tag(identity)),
                    model: nullish(&[
                        &row["providerData"]["model"],
                        &row["model"],
                        &row["message"]["model"],
                    ]),
                    cwd: &row["cwd"],
                    desktop: false,
                    candidates,
                    raw: &row["providerData"]["rawUsage"],
                },
                zone,
                notes,
            ) {
                out.push(r);
            }
        }
    }
    Ok(out)
}
