use serde_json::{json, Value};
use sha2::{Digest, Sha256};
pub(super) fn trim(text: &str) -> &str {
    text.trim_matches(|c:char| matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}'))
}
pub(super) fn note(notes: &mut Value, key: &str) {
    notes[key] = json!(notes[key].as_i64().unwrap_or(0) + 1);
}

pub fn file_tag(identity: &str) -> String {
    format!(
        "f{}",
        &format!("{:x}", Sha256::digest(identity.as_bytes()))[..12]
    )
}

pub(super) fn lines(bytes: &[u8], notes: &mut Value) -> Vec<(Value, usize)> {
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

pub(super) fn json(bytes: &[u8]) -> super::Result<Value> {
    super::super::jscompat::JsJson::parse(&String::from_utf8_lossy(bytes))
        .map(|v| v.to_value())
        .map_err(super::Error)
}
pub(super) fn nullish<'a>(values: &[&'a Value]) -> &'a Value {
    values
        .iter()
        .copied()
        .find(|v| !v.is_null())
        .unwrap_or(&Value::Null)
}
pub(super) fn fallback<'a>(values: &[&'a Value]) -> &'a Value {
    values
        .iter()
        .copied()
        .find(|v| super::super::jscompat::truthy(v))
        .unwrap_or(&Value::Null)
}
pub(super) fn optional(value: &Value) -> Option<String> {
    (!value.is_null()).then(|| super::super::jscompat::string(value))
}
pub(super) fn basename(identity: &str) -> &str {
    identity.rsplit(['/', '\\']).next().unwrap_or("")
}
pub(super) fn parent_name(identity: &str) -> &str {
    basename(identity.rsplit_once(['/', '\\']).map_or("", |(p, _)| p))
}
pub(super) fn event(
    source: &str,
    key: String,
    session: String,
    model: Option<String>,
    time: Option<String>,
    tokens: [Option<i64>; 4],
) -> Value {
    json!({"record_key":key,"source":source,"session_id":if session.is_empty(){None}else{Some(session)},"project_key":null,"model":model,"observed_at":time,"kind":"event","input_tokens":tokens[0],"output_tokens":tokens[1],"cache_read_tokens":tokens[2],"cache_write_tokens":tokens[3],"timestamp":time,"cache_creation_tokens":tokens[3]})
}
pub(super) fn empty(tokens: &[Option<i64>], notes: &mut Value) -> bool {
    let empty = tokens.iter().all(|v| v.unwrap_or(0) == 0);
    if empty {
        note(notes, "zero_usage");
    }
    empty
}
