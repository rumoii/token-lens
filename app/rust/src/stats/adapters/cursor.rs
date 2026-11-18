use super::super::{
    jscompat::{self, normalize_timestamp, string, JsJson, LocalZone},
    Result,
};
use super::{
    lines::{basename, empty, event, fallback, file_tag, note, nullish, trim},
    num::{plus, token},
    sqlite,
};
use serde_json::{json, Value};
use std::path::Path;

fn to_int(value: &Value, notes: &mut Value) -> Option<i64> {
    if let Some(s) = value.as_str() {
        token(
            &json!(s
                .chars()
                .filter(|c| *c != '$' && *c != ',' && !jscompat::whitespace(*c))
                .collect::<String>()),
            notes,
        )
    } else {
        token(value, notes)
    }
}
fn csv_row(chars: &[char], mut i: usize) -> (Vec<String>, usize) {
    let mut cells = Vec::new();
    let mut cell = String::new();
    let mut state = 0;
    while let Some(&ch) = chars.get(i) {
        if state == 1 {
            if ch == '"' {
                state = 3;
            } else {
                cell.push(ch);
            }
            i += 1;
            continue;
        }
        if state == 0 && ch == '"' {
            state = 1;
            i += 1;
            continue;
        }
        if state == 3 && ch == '"' {
            cell.push('"');
            state = 1;
            i += 1;
            continue;
        }
        match (state, ch) {
            (_, ',') => {
                cells.push(std::mem::take(&mut cell));
                state = 0;
                i += 1;
            }
            (_, '\n' | '\r') => {
                cells.push(cell);
                i += 1;
                if ch == '\r' && chars.get(i) == Some(&'\n') {
                    i += 1;
                }
                return (cells, i);
            }
            _ => {
                cell.push(ch);
                state = 2;
                i += 1;
            }
        }
    }
    cells.push(cell);
    (cells, i)
}

pub(super) fn csv(
    identity: &str,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let text = String::from_utf8_lossy(bytes);
    let chars = text.chars().collect::<Vec<_>>();
    if chars.is_empty() {
        return Ok(Vec::new());
    }
    let (header, mut cursor) = csv_row(&chars, 0);
    let header = header
        .iter()
        .map(|s| trim(s).to_lowercase())
        .collect::<Vec<_>>();
    let find = |f: fn(&str) -> bool| header.iter().position(|s| f(s));
    let (Some(date), Some(model)) = (find(|s| s == "date"), find(|s| s == "model")) else {
        return Ok(Vec::new());
    };
    let with = find(|s| s.contains("w/ cache write"));
    let without = find(|s| s.contains("w/o cache write") || s.contains("input tokens"));
    let read = find(|s| s.contains("cache read"));
    let output = find(|s| s.contains("output tokens"));
    let name = basename(identity);
    let session = name.strip_suffix(".csv").unwrap_or(name);
    let mut ordinal = 0;
    let mut out = Vec::new();
    while cursor < chars.len() {
        if matches!(chars[cursor], '\n' | '\r') {
            cursor += 1;
            continue;
        }
        let (cells, next) = csv_row(&chars, cursor);
        cursor = next;
        if cells.len() < 2 {
            continue;
        }
        let Some(raw) = cells.get(date).map(|s| trim(s)).filter(|s| !s.is_empty()) else {
            continue;
        };
        let model = cells
            .get(model)
            .map(|s| trim(s))
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let mut num = |index: Option<usize>| {
            index.and_then(|i| {
                to_int(
                    &cells.get(i).map(|s| json!(s)).unwrap_or(Value::Null),
                    notes,
                )
            })
        };
        let with = num(with);
        let input = num(without);
        let read = num(read);
        let output = num(output);
        let write = with.zip(input).map(|(a, b)| (a - b).max(0));
        let values = [input, output, read, write];
        if empty(&values, notes) {
            continue;
        }
        ordinal += 1;
        let time = normalize_timestamp(&json!(raw), zone);
        let mut record = event(
            "cursor",
            format!(
                "cursor|{}|{}|{ordinal}",
                file_tag(identity),
                time.as_deref().unwrap_or("null")
            ),
            session.into(),
            model,
            time.clone(),
            values,
        );
        record["replaces"] = json!([format!(
            "cursor|{session}|{}|{ordinal}",
            time.as_deref().unwrap_or("null")
        )]);
        out.push(record);
    }
    Ok(out)
}

pub(super) fn parse(
    identity: &str,
    file: &Path,
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let db = sqlite::open(file)?;
    let check = sqlite::get(
        &db,
        "SELECT count(*) as c FROM sqlite_master WHERE type='table' AND name='ItemTable'",
        &[],
        notes,
    )?;
    if check.is_none_or(|r| r["c"] == 0) {
        return Ok(Vec::new());
    }
    let rows = sqlite::query(
        &db,
        "SELECT key, value FROM ItemTable WHERE key IN (?, ?)",
        &[
            json!("composerData"),
            json!("workbench.panel.aichat.view.aichat.chatdata"),
        ],
        notes,
    )?;
    let mut out = Vec::new();
    for row in rows {
        let Some(text) = row["value"].as_str().filter(|s| !s.is_empty()) else {
            continue;
        };
        let parsed = match JsJson::parse(text) {
            Ok(v) => v,
            Err(_) => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let composer = row["key"] == "composerData";
        let entries = if composer {
            let root = parsed.get("composerData");
            if matches!(root, JsJson::Null) {
                parsed.values()
            } else {
                root.values()
            }
        } else {
            let tabs = parsed.get("tabs");
            if matches!(tabs, JsJson::Array(_)) {
                tabs.values()
            } else {
                parsed.values()
            }
        };
        for (index, item) in entries.into_iter().enumerate() {
            let item = item.to_value();
            if !item.is_object() && !item.is_array() {
                continue;
            }
            let msgs = if composer {
                nullish(&[&item["conversation"], &item["messages"], &item["tabs"]])
            } else {
                nullish(&[
                    &item["chatMessages"],
                    &item["messages"],
                    &item["conversation"],
                ])
            };
            let msgs = if msgs.is_null() {
                &[][..]
            } else if let Some(msgs) = msgs.as_array() {
                msgs.as_slice()
            } else {
                continue;
            };
            let mut input = None;
            let mut output = None;
            for msg in msgs {
                if !msg.is_object() && !msg.is_array() {
                    continue;
                }
                let count = to_int(
                    nullish(&[
                        &msg["tokenCount"],
                        &msg["tokens"],
                        &msg["usage"]["total_tokens"],
                    ]),
                    notes,
                );
                let user = msg["type"].as_f64() == Some(1.0)
                    || msg["role"] == "user"
                    || msg["isUser"] == true;
                if user {
                    input = plus(input, count);
                } else {
                    output = plus(output, count);
                }
            }
            let values = [input, output, None, None];
            if empty(&values, notes) {
                continue;
            }
            let model = fallback(&[&item["model"], &item["modelId"]]);
            let model = jscompat::truthy(model).then(|| string(model));
            let time = normalize_timestamp(
                nullish(&[
                    &item["createdAt"],
                    &item["lastSendTime"],
                    &item["timestamp"],
                ]),
                zone,
            );
            let id = nullish(&[
                &item["id"],
                &item[if composer { "composerId" } else { "tabId" }],
            ]);
            let has_id = !id.is_null();
            let session = if has_id {
                string(id)
            } else {
                if composer {
                    "composer-session"
                } else {
                    "chat-session"
                }
                .into()
            };
            let key = if has_id {
                format!("cursor|{session}")
            } else {
                format!(
                    "cursor|{}|{}:{index}",
                    file_tag(identity),
                    if composer { "composer" } else { "chat" }
                )
            };
            let mut record = event("cursor", key, session.clone(), model, time, values);
            record["session_id"] = json!(session);
            record["kind"] = json!("cumulative");
            if !has_id {
                record["replaces"] = json!([format!("cursor|{session}")]);
            }
            out.push(record);
        }
    }
    Ok(out)
}
