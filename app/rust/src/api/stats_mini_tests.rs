use super::*;
use chrono::DateTime;

#[test]
fn mini_snapshot_respects_local_day_and_exact_recent_range() {
    let time = |value: &str| {
        DateTime::parse_from_rfc3339(value)
            .unwrap()
            .timestamp_millis()
    };
    let midnight = time("2026-01-15T05:00:00Z");
    let now = time("2026-01-15T07:13:00Z");
    let temp = tempfile::tempdir().unwrap();
    let client = StatsClient::new_with_fixed_clock(
        temp.path().join("data").to_string_lossy().into(),
        Some(temp.path().join("home").to_string_lossy().into()),
        now,
    )
    .unwrap();
    let records: Vec<_> = [
        ("yesterday", "04:59:59.999", "codex", Some("/p"), 100),
        ("midnight", "05:00:00.000", "codex", Some("/p"), 10),
        ("outside-five", "07:07:59.999", "claude", None, 20),
        ("inside-five", "07:08:00.000", "claude", Some(""), 30),
        ("now", "07:13:00.000", "claude", Some("/p"), 40),
        ("future", "07:13:00.001", "codex", Some("/p"), 200),
        ("hidden", "07:10:00.000", "gemini", None, 300),
    ]
    .into_iter()
    .map(|(key, observed, source, project, tokens)| {
        json!({"record_key":key,"source":source,"session_id":"s","project_key":project,
            "model":key,"observed_at":format!("2026-01-15T{observed}Z"),"input_tokens":tokens})
    })
    .collect();
    let ledger = client.open().unwrap();
    ledger
        .batch(&records, None, None, &[], pricing::cost_of)
        .unwrap();
    ledger
        .db
        .execute(
            "UPDATE usage_records SET cost_micros=17 WHERE record_key='now'",
            [],
        )
        .unwrap();
    let data = client
        .mini_usage(midnight, now, vec!["gemini".into()])
        .unwrap();
    assert_eq!(data.totals.gross_tokens, 100);
    assert_eq!(data.totals.cost_micros, Some(17));
    assert_eq!(data.totals.unpriced_records, 3);
    assert_eq!(data.projects.len(), 2);
    assert_eq!(
        data.projects.iter().map(|p| p.gross_tokens).sum::<i64>(),
        100
    );
    let missing = data.projects.iter().find(|p| p.key.is_none()).unwrap();
    assert_eq!((missing.gross_tokens, missing.cost_micros), (50, None));
    let project = data.projects.iter().find(|p| p.key.is_some()).unwrap();
    assert_eq!((project.gross_tokens, project.cost_micros), (50, Some(17)));
    assert_eq!(project.tools.len(), 2);
    assert_eq!(data.hours, vec![10, 0, 90]);
    assert_eq!(data.active_models.len(), 2);
    assert_eq!(
        data.active_models
            .iter()
            .map(|m| m.gross_tokens)
            .sum::<i64>(),
        70
    );
    assert_eq!(data.requests.total, Some(4));
    assert_eq!(data.requests.items[0].id, "now");
}
