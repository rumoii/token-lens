use super::lines::trim;
use serde_json::Value;
pub(super) fn project(value: &Value) -> Option<String> {
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
