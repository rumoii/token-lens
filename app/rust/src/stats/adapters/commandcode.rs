use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

use super::project::project;
pub(super) fn parse(
    _identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let mut header = None;
    let mut out = Vec::new();
    for (row, _) in lines(bytes, notes) {
        if header.is_none() {
            if row["type"] != "session"
                || row["version"] != 3
                || row["id"].as_str().is_none_or(|s| trim(s).is_empty())
            {
                note(notes, "bad_lines");
                return Ok(out);
            }
            header = Some(row);
            continue;
        }
        if row["type"] != "message"
            || row["message"]["role"] != "assistant"
            || !jscompat::truthy(&row["usage"])
        {
            continue;
        }
        if row["id"].as_str().is_none_or(|s| trim(s).is_empty()) {
            note(notes, "bad_lines");
            continue;
        }
        let u = &row["usage"];
        let mut input = token_of(u, &["inputTokens"], notes);
        let output = token_of(u, &["outputTokens"], notes);
        let read = token_of(u, &["cacheReadTokens"], notes);
        let write = token_of(u, &["cacheWriteTokens"], notes);
        if let Some(v) = input {
            let n = v - read.unwrap_or(0) - write.unwrap_or(0);
            input = if n < 0 {
                note(notes, "bad_fields");
                None
            } else {
                Some(n)
            };
        }
        let tokens = [input, output, read, write];
        if empty(&tokens, notes) {
            continue;
        }
        let time = jscompat::normalize_timestamp(&row["timestamp"], zone);
        if time.is_none() {
            note(notes, "bad_times");
            continue;
        }
        let mut hour = token_of(u, &["cacheWriteTokens1h"], notes);
        if hour.is_some_and(|h| write.is_none_or(|w| h > w)) {
            note(notes, "bad_fields");
            hour = None;
        }
        let head = header.as_ref().unwrap();
        let session = head["id"].as_str().unwrap().to_owned();
        let mut r = event(
            "commandcode",
            format!("commandcode|{session}|{}", jscompat::string(&row["id"])),
            session,
            row["model"]
                .as_str()
                .map(trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            time,
            tokens,
        );
        r["project_key"] = json!(project(&head["cwd"]));
        r["cache_write_1h_tokens"] = json!(hour);
        r["cache_write_5m_tokens"] = json!(hour.map(|h| write.unwrap() - h));
        r.as_object_mut().unwrap().remove("timestamp");
        r.as_object_mut().unwrap().remove("cache_creation_tokens");
        out.push(r);
    }
    Ok(out)
}
