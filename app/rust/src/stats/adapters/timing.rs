use serde_json::{json, Value};

pub(super) fn milliseconds(v: &Value) -> Option<i64> {
    v.as_i64().filter(|n| *n >= 0)
}
pub(super) fn difference(end: Option<i64>, start: Option<i64>) -> Option<i64> {
    end.zip(start)
        .and_then(|(e, s)| e.checked_sub(s))
        .filter(|n| *n > 0)
}
pub(super) fn positive_ms(v: &Value) -> Option<i64> {
    v.as_f64()
        .filter(|n| n.is_finite() && *n > 0.0 && *n < i64::MAX as f64)
        .map(|n| n.round() as i64)
        .filter(|n| *n > 0)
}
pub(super) fn seconds(v: &Value) -> Option<i64> {
    v.as_f64().and_then(|n| positive_ms(&json!(n * 1000.0)))
}
pub(super) fn timestamp(v: &Value, zone: &super::LocalZone) -> Option<i64> {
    super::super::jscompat::normalize_timestamp(v, zone)
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
        .map(|t| t.timestamp_millis())
}
pub(super) fn duration(ms: Option<i64>, method: &str, status: &str, output: &Value) -> Value {
    let mut t = request(None, None, method, status, output);
    t["duration_ms"] = json!(ms);
    t["duration_method"] = json!(ms.map(|_| method));
    t
}
pub(super) fn content_event(data: &Value, output: &Value) -> Value {
    // SQLite JSON goes through the JS-compatible parser, which stores numbers as f64.
    let ms = |v: &Value| {
        v.as_f64()
            .filter(|n| n.is_finite() && *n >= 0.0 && n.fract() == 0.0 && *n <= 9007199254740991.0)
            .map(|n| n as i64)
    };
    let start = ms(&data["time"]["created"]);
    let end = ms(&data["time"]["completed"]);
    let starts: Option<Vec<_>> = data["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| c["type"] == "reasoning")
        .map(|c| ms(&c["time"]["created"]))
        .collect();
    // A missing earlier reasoning timestamp cannot be replaced by a later part.
    let first = starts.and_then(|starts| starts.into_iter().min());
    let mut t = request(
        difference(first, start),
        difference(end, first),
        "content_event_proxy",
        if end.is_some() {
            "completed"
        } else {
            "partial"
        },
        output,
    );
    t["duration_ms"] = json!(difference(end, start));
    t["duration_method"] = json!(difference(end, start).map(|_| "log_timestamps"));
    t
}
pub(super) fn request(
    ttft: Option<i64>,
    generation: Option<i64>,
    method: &str,
    status: &str,
    output: &Value,
) -> Value {
    json!({"ttft_ms":ttft,"ttft_method":ttft.map(|_| method),"generation_ms":generation,"generation_method":generation.map(|_|method),"timing_output_tokens":output,"scope":"request","status":status})
}
