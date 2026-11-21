use super::*;
use crate::stats::clock::Clock;

#[test]
fn mini_snapshot_excludes_commit_made_between_projections() {
    let temp = tempfile::tempdir().unwrap();
    let database = temp.path().join("ledger.db");
    let now = 1_768_478_400_000;
    let midnight = now - 12 * 3_600_000;
    let reader = Ledger::open(&database, Clock::Fixed(now)).unwrap();
    let writer = Ledger::open(&database, Clock::Fixed(now)).unwrap();
    let insert = |key, tokens| {
        writer
            .batch(
                &[json!({"record_key":key,"source":"claude","session_id":"s",
                    "project_key":"/synthetic","model":"unpriced","observed_at":"2026-01-15T12:00:00.000Z",
                    "input_tokens":tokens})],
                None,
                None,
                &[],
                pricing::cost_of,
            )
            .unwrap();
    };
    insert("before", 10);
    let snapshot = mini_usage_with(&reader, midnight, now, 15, &[], "UTC", || {
        insert("after", 20)
    })
    .unwrap();
    assert_eq!(snapshot["totals"]["gross_tokens"], 10);
    assert_eq!(snapshot["projects"][0]["gross_tokens"], 10);
    assert_eq!(snapshot["minutes"][14], 10);
    assert_eq!(snapshot["active_models"][0]["gross_tokens"], 10);
    assert_eq!(snapshot["requests"]["total"], 1);
    let latest = mini_usage(&reader, midnight, now, 15, &[], "UTC").unwrap();
    assert_eq!(latest["totals"]["gross_tokens"], 30);
    assert_eq!(latest["requests"]["total"], 2);
}
