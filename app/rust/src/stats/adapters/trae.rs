use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

fn usage(item: &Value, notes: &mut Value) -> Option<[Option<i64>; 4]> {
    let raw = fallback(&[&item["extra_info"], item]);
    let mut input = token_of(raw, &["input_token", "inputTokens", "input"], notes);
    let output = token_of(raw, &["output_token", "outputTokens", "output"], notes);
    let read = token_of(
        raw,
        &["cache_read_token", "cachedTokens", "cached_tokens"],
        notes,
    );
    let write = token_of(raw, &["cache_write_token", "cacheWriteTokens"], notes);
    if empty(&[input, output, read, write], notes) {
        return None;
    }
    if let (Some(i), Some(r)) = (input, read) {
        if r > 0 && i >= r {
            input = minus(input, read);
        }
    }
    Some([input, output, read, write])
}
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let name = basename(identity);
    let ext = name
        .rsplit_once('.')
        .map_or(String::new(), |(_, s)| format!(".{}", s.to_lowercase()));
    let default = name.strip_suffix(&ext).unwrap_or(name);
    let stream = ext == ".jsonl";
    let data;
    if stream {
        data = Value::Null;
    } else {
        data = json(bytes)?;
        if !data.is_object() && !data.is_array() {
            return Ok(vec![]);
        }
    }
    let rows = if stream {
        lines(bytes, notes).into_iter().map(|(v, _)| v).collect()
    } else {
        data.as_array()
            .or_else(|| data["sessions"].as_array())
            .cloned()
            .unwrap_or_else(|| vec![data.clone()])
    };
    let mut out = Vec::new();
    let mut ordinal = 0;
    for (index, item) in rows.iter().enumerate() {
        if !item.is_object() && !item.is_array() {
            continue;
        }
        let Some(tokens) = usage(item, notes) else {
            continue;
        };
        ordinal += 1;
        let session = optional(nullish(&[&item["session_id"], &item["id"]]))
            .unwrap_or_else(|| default.into());
        let time = jscompat::normalize_timestamp(
            nullish(&[&item["usage_time"], &item["timestamp"]]),
            zone,
        );
        let id = &item["message_id"];
        let key = if stream {
            if jscompat::truthy(id) {
                jscompat::string(id)
            } else {
                format!("{}|{ordinal}", time.as_deref().unwrap_or("null"))
            }
        } else {
            format!("{}:{index}", file_tag(identity))
        };
        let mut r = event(
            "trae",
            format!("trae|{session}|{key}"),
            session.clone(),
            optional(nullish(&[&item["model_name"], &item["model"]])),
            time.clone(),
            tokens,
        );
        if !stream {
            let has = !item["session_id"].is_null();
            r["kind"] = json!(if has { "cumulative" } else { "event" });
            r["replaces"] = json!([if has {
                format!("trae|{session}")
            } else {
                format!(
                    "trae|{session}|{}|{ordinal}",
                    time.as_deref().unwrap_or("null")
                )
            }]);
        }
        out.push(r);
    }
    Ok(out)
}
