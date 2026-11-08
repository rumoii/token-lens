use super::lines::{note, trim};
use serde_json::Value;
pub(super) fn token(value: &Value, notes: &mut Value) -> Option<i64> {
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

pub(super) fn token_of(object: &Value, keys: &[&str], notes: &mut Value) -> Option<i64> {
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
