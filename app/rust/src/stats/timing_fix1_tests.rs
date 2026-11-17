use super::{
    adapters,
    clock::Clock,
    jscompat::LocalZone,
    ledger::{rows, Ledger},
    pricing,
};
use rusqlite::Connection;
use serde_json::{json, Value};

const BASE: i64 = 1768435200000;
fn output(kind: &str, start: i64, end: Value) -> Value {
    json!({"type":"event_msg","timestamp":"2026-01-15T00:00:03.000Z","payload":{"type":"item_completed","item":{"type":kind},"started_at_ms":BASE+start,"completed_at_ms":end}})
}
fn usage(second: u8, id: &str) -> Value {
    json!({"type":"token_usage_record","timestamp":format!("2026-01-15T00:00:{second:02}.000Z"),"payload":{"session_id":"s","response_id":id,"usage":{"input_tokens":10,"output_tokens":100}}})
}
fn boundary() -> Value {
    json!({"type":"event_msg","timestamp":"2026-01-15T00:00:00.000Z","payload":{"type":"task_started"}})
}
fn parse(input: &[Value]) -> Vec<Value> {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("rollout-test.jsonl");
    std::fs::write(
        &file,
        input
            .iter()
            .map(|r| r.to_string() + "\n")
            .collect::<String>(),
    )
    .unwrap();
    adapters::parse("codex", "rollout-test.jsonl", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0
}
fn ledger() -> Ledger {
    Ledger::open(std::path::Path::new(":memory:"), Clock::Fixed(BASE)).unwrap()
}
fn timing(db: &Ledger) -> Value {
    rows(&db.db, "SELECT * FROM usage_timings", &[])
        .unwrap()
        .remove(0)
}

#[test]
fn fix5_reused_long_id_keeps_timing_of_last_usage() {
    let mut start_b = boundary();
    start_b["timestamp"] = json!("2026-01-15T00:00:05.000Z");
    let mut usage_b = usage(8, "resp_abcdef0123456789");
    usage_b["payload"]["usage"]["output_tokens"] = json!(200);
    let records = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        usage(4, "resp_abcdef0123456789"),
        start_b,
        output("AgentMessage", 6000, json!(BASE + 7000)),
        usage_b,
    ]);
    assert_eq!(records.len(), 2);
    assert_eq!(records[0]["record_key"], records[1]["record_key"]);
    for split in [false, true] {
        let db = ledger();
        if split {
            db.batch(&records[..1], Some("log"), Some(5), &[], pricing::cost_of)
                .unwrap();
            db.batch(&records[1..], Some("log"), Some(5), &[], pricing::cost_of)
                .unwrap();
        } else {
            db.batch(&records, Some("log"), Some(5), &[], pricing::cost_of)
                .unwrap();
        }
        for _ in 0..2 {
            let usage_rows = rows(
                &db.db,
                "SELECT output_tokens FROM usage_records WHERE active=1",
                &[],
            )
            .unwrap();
            assert_eq!(usage_rows, vec![json!({"output_tokens":200})]);
            let t = timing(&db);
            assert_eq!(t["timing_output_tokens"], 200);
            assert_eq!(t["ttft_ms"], 1000);
            assert_eq!(t["generation_ms"], 2000);
            let summary = db.timing_summary(&json!({})).unwrap();
            assert_eq!(summary["request_count"], 1);
            assert_eq!(summary["speed"][0]["tokens_per_second"], 100.0);
            db.batch(&records, Some("log"), Some(5), &[], pricing::cost_of)
                .unwrap();
        }
    }
}

#[test]
fn fix5_changed_usage_without_timing_deletes_previous_group() {
    for (field, value) in [
        ("output_tokens", json!(200)),
        ("input_tokens", json!(20)),
        ("model", json!("new-model")),
        ("observed_at", json!("2026-01-15T00:00:08.000Z")),
    ] {
        let db = ledger();
        let mut r = parse(&[
            boundary(),
            output("Reasoning", 1000, json!(BASE + 2000)),
            usage(4, "resp_abcdef0123456789"),
        ])
        .remove(0);
        db.batch(
            std::slice::from_ref(&r),
            Some("log"),
            Some(5),
            &[],
            pricing::cost_of,
        )
        .unwrap();
        assert_eq!(timing(&db)["generation_ms"], 3000);
        let old_hash = rows(&db.db, "SELECT content_hash FROM usage_records", &[]).unwrap();
        r[field] = value;
        r.as_object_mut().unwrap().remove("timing");
        db.batch(&[r], Some("log"), Some(5), &[], pricing::cost_of)
            .unwrap();
        assert_ne!(
            rows(&db.db, "SELECT content_hash FROM usage_records", &[]).unwrap(),
            old_hash
        );
        assert!(
            rows(&db.db, "SELECT * FROM usage_timings", &[])
                .unwrap()
                .is_empty(),
            "{field}"
        );
        let summary = db.timing_summary(&json!({})).unwrap();
        assert_eq!(summary["request_count"], 1);
        assert!(summary["ttft"].is_null(), "{field}");
        assert!(summary["speed"].is_null(), "{field}");
    }
}

#[test]
fn fix4_equal_late_boundary_keeps_first_output_and_origin() {
    for mut b in [
        json!({"type":"event_msg","payload":{"type":"task_started"}}),
        json!({"type":"event_msg","payload":{"type":"turn_started"}}),
        json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage"}}}),
        json!({"type":"response_item","payload":{"type":"message","role":"user"}}),
        json!({"type":"response_item","payload":{"type":"function_call_output"}}),
        json!({"type":"response_item","payload":{"type":"custom_tool_call_output"}}),
    ] {
        b["timestamp"] = json!("2026-01-15T00:00:05.000Z");
        let mut start = boundary();
        start["timestamp"] = b["timestamp"].clone();
        let r = parse(&[
            start,
            output("Reasoning", 6000, json!(BASE + 7000)),
            b.clone(),
            output("AgentMessage", 7000, json!(BASE + 8000)),
            usage(8, "resp_abcdef0123456789"),
        ]);
        assert_eq!(r[0]["timing"]["ttft_ms"], 1000, "{b}");
        assert_eq!(r[0]["timing"]["generation_ms"], 2000, "{b}");
        let db = ledger();
        db.batch(&r, Some("log"), Some(5), &[], pricing::cost_of)
            .unwrap();
        assert_eq!(
            db.timing_summary(&json!({})).unwrap()["speed"][0]["tokens_per_second"],
            50.0
        );
    }
}

#[test]
fn fix4_equal_user_boundary_before_output_keeps_request_start() {
    let mut start = boundary();
    start["timestamp"] = json!("2026-01-15T00:00:05.000Z");
    for payload in [
        json!({"type":"message","role":"user"}),
        json!({"type":"item_completed","item":{"type":"UserMessage"}}),
    ] {
        let kind = if payload["type"] == "message" {
            "response_item"
        } else {
            "event_msg"
        };
        let r = parse(&[
            start.clone(),
            json!({"type":kind,"timestamp":start["timestamp"],"payload":payload}),
            output("Reasoning", 6000, json!(BASE + 7000)),
            usage(8, "resp_abcdef0123456789"),
        ]);
        assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
        assert_eq!(r[0]["timing"]["generation_ms"], 2000);
    }
}

#[test]
fn fix4_equal_abort_still_clears_confirmed_output() {
    let mut start = boundary();
    start["timestamp"] = json!("2026-01-15T00:00:05.000Z");
    let r = parse(&[
        start.clone(),
        output("Reasoning", 6000, json!(BASE + 7000)),
        json!({"type":"event_msg","timestamp":start["timestamp"],"payload":{"type":"turn_aborted"}}),
        usage(8, "resp_abcdef0123456789"),
    ]);
    assert!(r[0]["timing"]["ttft_ms"].is_null());
    assert!(r[0]["timing"]["generation_ms"].is_null());
}

#[test]
fn fix4_later_boundary_still_starts_new_window_after_output() {
    let mut start = boundary();
    start["timestamp"] = json!("2026-01-15T00:00:05.000Z");
    let r = parse(&[
        start,
        output("Reasoning", 6000, json!(BASE + 7000)),
        json!({"type":"response_item","timestamp":"2026-01-15T00:00:07.000Z","payload":{"type":"function_call_output"}}),
        output("AgentMessage", 8000, json!(BASE + 8500)),
        usage(9, "resp_abcdef0123456789"),
    ]);
    assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
    assert_eq!(r[0]["timing"]["generation_ms"], 1000);
}

#[test]
fn fix4_replaces_deletes_old_timing_without_revision_change() {
    let db = ledger();
    let a = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        usage(4, "resp_abcdef0123456789"),
    ])
    .remove(0);
    db.batch(
        std::slice::from_ref(&a),
        Some("old"),
        Some(5),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(timing(&db)["record_key"], a["record_key"]);
    let mut b = a.clone();
    b["record_key"] = json!("codex|s|resp_abcdef0123456780");
    b["replaces"] = json!([a["record_key"]]);
    let before = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    let before_timing = timing(&db);
    let cancelled = std::cell::Cell::new(false);
    let result = db.batch_cancellable(
        std::slice::from_ref(&b),
        Some("new"),
        super::ledger::Revisions {
            usage: Some(5),
            timing: Some(1),
        },
        &[],
        |r| {
            cancelled.set(true);
            pricing::cost_of(r)
        },
        || cancelled.get(),
    );
    assert_eq!(result.unwrap_err().0, "cancelled");
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
        before
    );
    assert_eq!(timing(&db), before_timing);
    for _ in 0..2 {
        db.batch(
            std::slice::from_ref(&b),
            Some("new"),
            Some(5),
            &[],
            pricing::cost_of,
        )
        .unwrap();
        let old = rows(
            &db.db,
            "SELECT active,superseded_by FROM usage_records WHERE record_key=?",
            &[a["record_key"].clone()],
        )
        .unwrap();
        let new_id = rows(
            &db.db,
            "SELECT id FROM usage_records WHERE record_key=?",
            &[b["record_key"].clone()],
        )
        .unwrap()[0]["id"]
            .clone();
        assert_eq!(old[0]["active"], 0);
        assert_eq!(old[0]["superseded_by"], new_id);
        let timings = rows(
            &db.db,
            "SELECT record_key,parser_rev FROM usage_timings",
            &[],
        )
        .unwrap();
        assert_eq!(
            timings,
            vec![json!({"record_key":b["record_key"],"parser_rev":1})]
        );
    }
}

#[test]
fn fix3_timing_upgrade_preserves_pruned_usage_and_money() {
    for (source, baseline) in [("codex", 5), ("kimi", 5), ("zcode", 1)] {
        let db = ledger();
        let mut a = parse(&[usage(8, "resp_abcdef0123456789")]).remove(0);
        a["source"] = json!(source);
        a["timing"]["generation_ms"] = json!(7000);
        a["timing"]["generation_method"] = json!("log_timestamps");
        let a_key = a["record_key"].clone();
        let mut b = a.clone();
        b["record_key"] = json!(format!("{source}:b"));
        let price = |_: &Value| json!({"cost_micros":123,"price_version":"fixture","price_source":"fixture"});
        db.batch(&[a, b.clone()], Some("log"), Some(baseline), &[], price)
            .unwrap();
        let before = rows(&db.db, "SELECT count(*) AS requests,sum(input_tokens+output_tokens) AS tokens,sum(cost_micros) AS money FROM usage_records WHERE active=1", &[]).unwrap();
        let usage_before = rows(
            &db.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[],
        )
        .unwrap();
        b["timing"]["generation_ms"] = json!(2000);
        db.batch_with_timing_revision(
            &[b.clone()],
            Some("log"),
            Some(adapters::parser_rev(source)),
            Some(2),
            &[],
            price,
        )
        .unwrap();
        assert_eq!(rows(&db.db, "SELECT count(*) AS requests,sum(input_tokens+output_tokens) AS tokens,sum(cost_micros) AS money FROM usage_records WHERE active=1", &[]).unwrap(), before, "{source}");
        assert_eq!(
            rows(
                &db.db,
                "SELECT active FROM usage_records WHERE record_key=?",
                &[a_key]
            )
            .unwrap()[0]["active"],
            1
        );
        assert_eq!(
            rows(
                &db.db,
                "SELECT * FROM usage_records ORDER BY record_key",
                &[]
            )
            .unwrap(),
            usage_before
        );
        assert_eq!(db.timing_summary(&json!({})).unwrap()["request_count"], 2);
        assert_eq!(
            rows(
                &db.db,
                "SELECT parser_rev FROM usage_timings WHERE record_key=?",
                &[b["record_key"].clone()]
            )
            .unwrap()[0]["parser_rev"],
            2
        );
        assert_eq!(
            rows(
                &db.db,
                "SELECT generation_ms FROM usage_timings WHERE record_key=?",
                &[b["record_key"].clone()]
            )
            .unwrap()[0]["generation_ms"],
            2000
        );
    }
}

#[test]
fn fix3_usage_parser_revisions_stay_at_baseline() {
    assert_eq!(adapters::TIMING_REV.len(), 12);
    assert_eq!(adapters::timing_rev("claude"), Some(2));
    for (source, revision) in [("codex", 5), ("kimi", 5), ("zcode", 1)] {
        assert_eq!(adapters::parser_rev(source), revision, "{source}");
        assert_eq!(adapters::timing_rev(source), Some(1), "{source}");
    }
}

#[test]
fn fix3_completed_group_is_immutable_even_without_ttft_or_with_superset() {
    for (ttft, incoming) in [
        (Value::Null, Value::Null),
        (Value::Null, json!(500)),
        (json!(1000), json!(500)),
    ] {
        let db = ledger();
        let u = usage(8, "resp_abcdef0123456789");
        let reply = output("AgentMessage", 6000, json!(BASE + 7000));
        let mut r = parse(&[
            output("Reasoning", 1000, json!(BASE + 2000)),
            reply.clone(),
            u.clone(),
        ])
        .remove(0);
        assert!(r["timing"]["ttft_ms"].is_null());
        assert_eq!(r["timing"]["generation_ms"], 7000);
        r["timing"]["ttft_ms"] = ttft.clone();
        r["timing"]["ttft_method"] = if ttft.is_null() {
            Value::Null
        } else {
            json!("log_timestamps")
        };
        r["timing"]["generation_ms"] = json!(7000);
        r["timing"]["generation_method"] = json!("log_timestamps");
        db.batch(&[r.clone()], Some("log"), Some(5), &[], pricing::cost_of)
            .unwrap();
        let old = timing(&db);
        r = parse(&[reply, u]).remove(0);
        assert!(r["timing"]["ttft_ms"].is_null());
        assert_eq!(r["timing"]["generation_ms"], 2000);
        r["timing"]["ttft_ms"] = incoming.clone();
        r["timing"]["ttft_method"] = if incoming.is_null() {
            Value::Null
        } else {
            json!("client_reported")
        };
        db.batch(&[r], Some("log"), Some(5), &[], pricing::cost_of)
            .unwrap();
        assert_eq!(timing(&db), old);
        let speed = db.timing_summary(&json!({})).unwrap()["speed"][0]["tokens_per_second"]
            .as_f64()
            .unwrap();
        assert!((speed - 100.0 / 7.0).abs() < 1e-9);
    }
}

#[test]
fn fix3_incomplete_unknown_group_requires_incoming_timing_before_replacement() {
    let db = ledger();
    let mut r = parse(&[usage(8, "resp_abcdef0123456789")]).remove(0);
    r["timing"]["status"] = json!("partial");
    db.batch(&[r.clone()], Some("log"), Some(5), &[], pricing::cost_of)
        .unwrap();
    let old = timing(&db);
    r.as_object_mut().unwrap().remove("timing");
    db.batch(&[r], Some("log"), Some(5), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap(),
        vec![old]
    );
}

#[test]
fn fix3_late_or_undated_boundaries_preserve_current_origin_and_output() {
    for mut b in [
        json!({"type":"event_msg","payload":{"type":"turn_aborted"}}),
        json!({"type":"event_msg","payload":{"type":"task_started"}}),
        json!({"type":"event_msg","payload":{"type":"turn_started"}}),
        json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage"}}}),
        json!({"type":"response_item","payload":{"type":"message","role":"user"}}),
        json!({"type":"response_item","payload":{"type":"function_call_output"}}),
        json!({"type":"response_item","payload":{"type":"custom_tool_call_output"}}),
    ] {
        for timestamp in [Value::Null, json!("2026-01-15T00:00:02.000Z")] {
            b["timestamp"] = timestamp;
            let mut start = boundary();
            start["timestamp"] = json!("2026-01-15T00:00:05.000Z");
            let r = parse(&[
                start,
                output("Reasoning", 6000, json!(BASE + 7000)),
                b.clone(),
                output("AgentMessage", 7000, json!(BASE + 8000)),
                usage(8, "resp_abcdef0123456789"),
            ]);
            assert_eq!(r[0]["timing"]["ttft_ms"], 1000, "{b}");
            assert_eq!(r[0]["timing"]["generation_ms"], 2000, "{b}");
            let db = ledger();
            db.batch(&r, Some("log"), Some(5), &[], pricing::cost_of)
                .unwrap();
            assert_eq!(
                db.timing_summary(&json!({})).unwrap()["speed"][0]["tokens_per_second"],
                50.0
            );
        }
    }
}

#[test]
fn fix1_late_item_before_previous_usage_cannot_pollute_next_request() {
    let a = output("Reasoning", 1000, json!(BASE + 2000));
    let r = parse(&[
        boundary(),
        a.clone(),
        usage(4, "resp_abcdef0123456789"),
        a,
        output("AgentMessage", 6000, json!(BASE + 7000)),
        usage(8, "resp_abcdef0123456780"),
    ]);
    assert_eq!(r[0]["timing"]["generation_ms"], 3000);
    assert_eq!(r[1]["timing"]["generation_ms"], 2000);
    assert_eq!(r[1]["timing"]["timing_output_tokens"], 100);
    assert!(r[1]["timing"]["ttft_ms"].is_null());
}
#[test]
fn fix1_zero_duration_reasoning_defers_to_positive_duration_reply() {
    let r = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 1000)),
        output("AgentMessage", 3000, json!(BASE + 3500)),
        usage(4, "resp_abcdef0123456789"),
    ]);
    assert_eq!(r[0]["timing"]["ttft_ms"], 3000);
    assert_eq!(r[0]["timing"]["generation_ms"], 1000);
}
#[test]
fn fix1_zero_missing_or_reversed_item_duration_has_no_timing() {
    for kind in ["Reasoning", "AgentMessage"] {
        for end in [json!(BASE + 1000), Value::Null, json!(BASE + 999)] {
            let r = parse(&[
                boundary(),
                output(kind, 1000, end),
                usage(4, "resp_abcdef0123456789"),
            ]);
            assert!(r[0]["timing"]["ttft_ms"].is_null());
            assert!(r[0]["timing"]["generation_ms"].is_null());
        }
    }
}
#[test]
fn fix1_same_revision_cropped_events_preserve_metrics_hash_and_coverage() {
    let db = ledger();
    let u = usage(4, "resp_abcdef0123456789");
    let full = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        u.clone(),
    ]);
    let cropped = parse(&[u]);
    db.batch_with_timing_revision(&full, Some("log"), Some(5), Some(1), &[], pricing::cost_of)
        .unwrap();
    let before = db.timing_summary(&json!({})).unwrap();
    let row = timing(&db);
    let usage_before = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    db.batch_with_timing_revision(
        &cropped,
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(db.timing_summary(&json!({})).unwrap(), before);
    assert_eq!(timing(&db), row);
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
        usage_before
    );
    let changes = db.db.total_changes();
    db.batch_with_timing_revision(
        &cropped,
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(db.db.total_changes(), changes);
    db.batch_with_timing_revision(
        &cropped,
        Some("log"),
        Some(5),
        Some(2),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let result = db.timing_summary(&json!({})).unwrap();
    assert!(result["ttft"].is_null() && result["speed"].is_null());
    assert_eq!(result["request_count"], 1);
}
#[test]
fn fix1_cropped_group_retains_status_and_output_then_replaces_new_revision() {
    let db = ledger();
    let mut r = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        usage(4, "resp_abcdef0123456789"),
    ])
    .remove(0);
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    r["timing"]["ttft_ms"] = Value::Null;
    r["timing"]["ttft_method"] = Value::Null;
    r["timing"]["generation_ms"] = json!(1500);
    r["timing"]["generation_method"] = json!("client_reported");
    r["timing"]["timing_output_tokens"] = Value::Null;
    r["timing"]["status"] = Value::Null;
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let result = timing(&db);
    assert_eq!(result["ttft_ms"], 1000);
    assert_eq!(result["ttft_method"], "log_timestamps");
    assert_eq!(result["generation_ms"], 3000);
    assert_eq!(result["generation_method"], "log_timestamps");
    assert_eq!(result["timing_output_tokens"], 100);
    assert_eq!(result["status"], "completed");
    r["timing"]["status"] = json!("unknown");
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(timing(&db)["status"], "completed");
    r["timing"]["status"] = json!("partial");
    r["timing"]["timing_output_tokens"] = json!(50);
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(timing(&db)["status"], "completed");
    assert_eq!(timing(&db)["timing_output_tokens"], 100);
    r["timing"]["generation_ms"] = Value::Null;
    r["timing"]["generation_method"] = Value::Null;
    r["timing"]["status"] = Value::Null;
    r["timing"]["timing_output_tokens"] = Value::Null;
    db.batch_with_timing_revision(&[r], Some("log"), Some(5), Some(2), &[], pricing::cost_of)
        .unwrap();
    let result = timing(&db);
    assert!(result["ttft_ms"].is_null() && result["generation_ms"].is_null());
    assert!(result["timing_output_tokens"].is_null());
    assert_eq!(result["status"], "unknown");
}
#[test]
fn fix1_codex_revision_replaces_previous_ineligible_timing() {
    assert_eq!(adapters::parser_rev("codex"), 5);
    let db = ledger();
    let u = usage(4, "resp_abcdef0123456789");
    let mut old = parse(std::slice::from_ref(&u)).remove(0);
    old["timing"]["ttft_ms"] = json!(1000);
    old["timing"]["ttft_method"] = json!("log_timestamps");
    old["timing"]["generation_ms"] = json!(3000);
    old["timing"]["generation_method"] = json!("log_timestamps");
    db.batch_with_timing_revision(&[old], Some("log"), Some(5), Some(1), &[], pricing::cost_of)
        .unwrap();
    let r = parse(&[boundary(), output("Reasoning", 1000, json!(BASE + 1000)), u]);
    db.batch_with_timing_revision(
        &r,
        Some("log"),
        Some(adapters::parser_rev("codex")),
        Some(2),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert!(db.timing_summary(&json!({})).unwrap()["speed"].is_null());
}

#[test]
fn fix1_existing_writer_paths_tolerate_legacy_dangling_superseded_by() {
    let mut snapshots = Vec::new();
    for enforce in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("ledger.db");
        let initial = Connection::open(&file).unwrap();
        initial
            .execute_batch(include_str!("ledger/schema.sql"))
            .unwrap();
        initial
            .execute_batch("PRAGMA foreign_keys=OFF; PRAGMA user_version=5;")
            .unwrap();
        let mut r = parse(&[usage(4, "resp_abcdef0123456789")]).remove(0);
        let key = r["record_key"].as_str().unwrap().to_owned();
        initial.execute("INSERT INTO usage_records(record_key,content_hash,source,session_id,kind,observed_at,input_tokens,output_tokens,source_file,parser_rev,superseded_by) VALUES (?,?,'codex','s','event',?,10,100,'log',6,999999)",rusqlite::params![key,super::ledger::payload_hash(&r),r["observed_at"].as_str()]).unwrap();
        drop(initial);
        let db = Ledger::open(&file, Clock::Fixed(BASE)).unwrap();
        assert_eq!(
            db.db
                .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            1
        );
        if !enforce {
            db.db.execute_batch("PRAGMA foreign_keys=OFF").unwrap();
        }
        // Touch, relabel and growth update columns other than the foreign-key reference.
        db.batch(&[r.clone()], Some("log"), Some(6), &[], pricing::cost_of)
            .unwrap();
        r["project_key"] = json!("project");
        db.batch(&[r.clone()], Some("log"), Some(6), &[], pricing::cost_of)
            .unwrap();
        r["output_tokens"] = json!(110);
        db.batch(&[r.clone()], Some("log"), Some(6), &[], pricing::cost_of)
            .unwrap();
        db.reprice(
            "fixture-v2",
            |_| json!({"price_version":"fixture-v2","price_source":"fixture","cost_micros":42}),
        )
        .unwrap();
        assert_eq!(
            rows(
                &db.db,
                "SELECT superseded_by FROM usage_records WHERE record_key=?",
                &[json!(key)]
            )
            .unwrap()[0]["superseded_by"],
            999999
        );
        let mut keep = r.clone();
        keep["record_key"] = json!("keep");
        let vanished = db
            .batch(&[keep.clone()], Some("log"), Some(6), &[], pricing::cost_of)
            .unwrap();
        assert_eq!(vanished["counts"]["vanished"], 1);
        let run = db.begin_run().unwrap();
        db.finish_run(run, "ok", &vanished).unwrap();
        db.batch(&[keep], Some("log"), Some(7), &[], pricing::cost_of)
            .unwrap();
        assert_eq!(
            rows(
                &db.db,
                "SELECT active FROM usage_records WHERE record_key=?",
                &[json!(key)]
            )
            .unwrap()[0]["active"],
            0
        );
        db.db
            .execute(
                "UPDATE usage_records SET active=1 WHERE record_key=?",
                [key.as_str()],
            )
            .unwrap();
        let mut replacement = r.clone();
        replacement["record_key"] = json!("replacement");
        replacement["replaces"] = json!([key]);
        db.batch(
            &[replacement],
            Some("other"),
            Some(7),
            &[],
            pricing::cost_of,
        )
        .unwrap();
        let old = rows(
            &db.db,
            "SELECT active,superseded_by FROM usage_records WHERE record_key=?",
            &[json!(key)],
        )
        .unwrap();
        assert_eq!(old[0]["active"], 0);
        assert_eq!(old[0]["superseded_by"], 3);
        snapshots.push((rows(&db.db,"SELECT record_key,active,superseded_by,cost_micros,output_tokens,revision FROM usage_records ORDER BY record_key",&[]).unwrap(),db.last_run().unwrap()));
        // Only actually assigning a missing FK target is rejected with enforcement on.
        assert_eq!(
            db.db
                .execute(
                    "UPDATE usage_records SET superseded_by=999999 WHERE record_key='replacement'",
                    []
                )
                .is_err(),
            enforce
        );
    }
    assert_eq!(snapshots[0], snapshots[1]);
}

#[test]
fn fix2_cropped_earlier_output_keeps_entire_original_window() {
    let db = ledger();
    let u = usage(8, "resp_abcdef0123456789");
    let reply = output("AgentMessage", 6000, json!(BASE + 7000));
    let full = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        reply.clone(),
        u.clone(),
    ]);
    let cropped = parse(&[reply, u]);
    assert!(cropped[0]["timing"]["ttft_ms"].is_null());
    assert_eq!(cropped[0]["timing"]["generation_ms"], 2000);
    db.batch(&full, Some("log"), Some(7), &[], pricing::cost_of)
        .unwrap();
    let original = timing(&db);
    let before = db.timing_summary(&json!({})).unwrap();
    for _ in 0..2 {
        db.batch(&cropped, Some("log"), Some(7), &[], pricing::cost_of)
            .unwrap();
    }
    assert_eq!(timing(&db), original);
    assert_eq!(timing(&db)["ttft_ms"], 1000);
    assert_eq!(timing(&db)["generation_ms"], 7000);
    assert_eq!(db.timing_summary(&json!({})).unwrap(), before);
    assert!(
        (before["speed"][0]["tokens_per_second"].as_f64().unwrap() - 100000.0 / 7000.0).abs()
            < 1e-10
    );
    let changes = db.db.total_changes();
    db.batch(&cropped, Some("log"), Some(7), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(db.db.total_changes(), changes);
}

#[test]
fn fix2_owner_change_does_not_fill_earlier_original_from_later_copy() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let logs = home.join(".codex/sessions");
    std::fs::create_dir_all(&logs).unwrap();
    let mut u = usage(8, "resp_abcdef0123456789");
    u["payload"]["usage"]["model"] = json!("target");
    let content = |r: &[Value]| r.iter().map(|v| v.to_string() + "\n").collect::<String>();
    std::fs::write(
        logs.join("rollout-b.jsonl"),
        content(&[
            boundary(),
            output("Reasoning", 1000, json!(BASE + 2000)),
            u.clone(),
        ]),
    )
    .unwrap();
    let env = super::ingest::Environment {
        platform: "win32".into(),
        vars: ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"]
            .map(|key| (key.into(), home.join(key).to_string_lossy().into_owned()))
            .into(),
    };
    let sync = || {
        super::ingest::sync(
            &root.path().join("data"),
            &home,
            &env,
            Clock::Fixed(BASE),
            &LocalZone::Fixed(0),
            &std::sync::atomic::AtomicBool::new(false),
        )
        .unwrap()
    };
    sync();
    let db = Ledger::open(&root.path().join("data/ledger.db"), Clock::Fixed(BASE)).unwrap();
    assert_eq!(
        db.timing_summary(&json!({"model":"target"})).unwrap()["speed"][0]["sample_count"],
        1
    );
    let mut anchor = usage(1, "resp_abcdef0123456780");
    anchor["payload"]["usage"]["model"] = json!("anchor");
    std::fs::write(logs.join("rollout-a.jsonl"), content(&[anchor, u])).unwrap();
    let result = sync();
    assert_eq!(result["counts"]["cross_file_copies"], 1);
    let summary = db.timing_summary(&json!({"model":"target"})).unwrap();
    assert_eq!(summary["request_count"], 1);
    assert!(summary["ttft"].is_null() && summary["speed"].is_null());
    let row=rows(&db.db,"SELECT t.* FROM usage_timings t JOIN usage_records u USING(record_key) WHERE u.model='target'",&[]).unwrap();
    assert!(row[0]["source_file"]
        .as_str()
        .unwrap()
        .ends_with("rollout-a.jsonl"));
    sync();
    assert_eq!(
        db.timing_summary(&json!({"model":"target"})).unwrap(),
        summary
    );
}

#[test]
fn fix2_zcode_completion_superset_replaces_entire_partial_group() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("zcode.db");
    let source = Connection::open(&file).unwrap();
    source.execute_batch("CREATE TABLE model_usage(id TEXT,session_id TEXT,model_id TEXT,provider_id TEXT,started_at INTEGER,input_tokens INTEGER,output_tokens INTEGER,cache_read_input_tokens INTEGER,cache_creation_input_tokens INTEGER,first_token_at INTEGER,completed_at INTEGER,time_to_first_token_ms INTEGER,status TEXT); INSERT INTO model_usage VALUES ('a','s','m','p',1768435200000,10,100,0,0,1768435201000,NULL,1000,'running')").unwrap();
    let parse = || {
        adapters::parse("zcode", "zcode.db", &file, &LocalZone::Fixed(0))
            .unwrap()
            .0
    };
    let db = ledger();
    db.batch(&parse(), Some("zcode.db"), Some(2), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(timing(&db)["ttft_ms"], 1000);
    assert!(timing(&db)["generation_ms"].is_null());
    assert_eq!(timing(&db)["status"], "partial");
    source.execute_batch("UPDATE model_usage SET first_token_at=1768435201200,time_to_first_token_ms=1200,completed_at=1768435208000,status='completed',output_tokens=200").unwrap();
    db.batch(&parse(), Some("zcode.db"), Some(2), &[], pricing::cost_of)
        .unwrap();
    let row = timing(&db);
    assert_eq!(row["ttft_ms"], 1200);
    assert_eq!(row["generation_ms"], 6800);
    assert_eq!(row["status"], "completed");
    assert_eq!(row["timing_output_tokens"], 200);
}

#[test]
fn fix2_retained_and_replaced_groups_never_mix_methods_status_or_output() {
    let db = ledger();
    let mut original = parse(&[
        boundary(),
        output("Reasoning", 1000, json!(BASE + 2000)),
        usage(8, "resp_abcdef0123456789"),
    ])
    .remove(0);
    original["timing"]["status"] = json!("partial");
    db.batch(
        std::slice::from_ref(&original),
        Some("log"),
        Some(7),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let old = timing(&db);
    let mut next = original.clone();
    next["timing"]["ttft_ms"] = Value::Null;
    next["timing"]["ttft_method"] = Value::Null;
    next["timing"]["generation_ms"] = json!(2000);
    next["timing"]["generation_method"] = json!("client_reported");
    next["timing"]["status"] = json!("partial");
    next["timing"]["timing_output_tokens"] = json!(50);
    db.batch(
        std::slice::from_ref(&next),
        Some("log"),
        Some(7),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(timing(&db), old);
    next["timing"]["ttft_ms"] = json!(2000);
    next["timing"]["ttft_method"] = json!("client_reported");
    next["timing"]["status"] = Value::Null;
    next["timing"]["timing_output_tokens"] = Value::Null;
    db.batch(&[next], Some("log"), Some(7), &[], pricing::cost_of)
        .unwrap();
    let row = timing(&db);
    assert_eq!(row["ttft_ms"], 2000);
    assert_eq!(row["generation_ms"], 2000);
    assert_eq!(row["ttft_method"], "client_reported");
    assert_eq!(row["generation_method"], "client_reported");
    assert_eq!(row["status"], "unknown");
    assert!(row["timing_output_tokens"].is_null());
}

#[test]
fn fix2_aborted_request_late_item_cannot_pollute_new_turn() {
    let mut abort = boundary();
    abort["timestamp"] = json!("2026-01-15T00:00:03.000Z");
    abort["payload"]["type"] = json!("turn_aborted");
    let mut start = boundary();
    start["timestamp"] = json!("2026-01-15T00:00:05.000Z");
    let a = output("Reasoning", 1000, json!(BASE + 2000));
    let r = parse(&[
        boundary(),
        a.clone(),
        abort,
        start,
        a,
        output("AgentMessage", 6000, json!(BASE + 7000)),
        usage(8, "resp_abcdef0123456789"),
    ]);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
    assert_eq!(r[0]["timing"]["generation_ms"], 2000);
    let db = ledger();
    db.batch(&r, Some("log"), Some(8), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        db.timing_summary(&json!({})).unwrap()["speed"][0]["tokens_per_second"],
        50.0
    );
}

#[test]
fn fix2_every_boundary_advances_monotonic_output_lower_bound() {
    let boundaries = [
        json!({"type":"event_msg","payload":{"type":"turn_aborted"}}),
        json!({"type":"event_msg","payload":{"type":"task_started"}}),
        json!({"type":"event_msg","payload":{"type":"turn_started"}}),
        json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage"}}}),
        json!({"type":"response_item","payload":{"type":"message","role":"user"}}),
        json!({"type":"response_item","payload":{"type":"function_call_output"}}),
        json!({"type":"response_item","payload":{"type":"custom_tool_call_output"}}),
    ];
    for mut b in boundaries {
        b["timestamp"] = json!("2026-01-15T00:00:05.000Z");
        let r = parse(&[
            boundary(),
            b.clone(),
            output("Reasoning", 1000, json!(BASE + 2000)),
            output("AgentMessage", 6000, json!(BASE + 7000)),
            usage(8, "resp_abcdef0123456789"),
        ]);
        assert_eq!(r[0]["timing"]["generation_ms"], 2000);
        if b["payload"]["type"] == "turn_aborted" {
            assert!(r[0]["timing"]["ttft_ms"].is_null());
        } else {
            assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
        }
    }
    let r = parse(&[
        json!({"type":"event_msg","timestamp":"2026-01-15T00:00:05.000Z","payload":{"type":"task_started"}}),
        output("Reasoning", 6000, json!(BASE + 7000)),
        json!({"type":"response_item","timestamp":"2026-01-15T00:00:02.000Z","payload":{"type":"function_call_output"}}),
        output("AgentMessage", 3000, json!(BASE + 4000)),
        output("AgentMessage", 7000, json!(BASE + 8000)),
        usage(8, "resp_abcdef0123456789"),
    ]);
    assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
    assert_eq!(r[0]["timing"]["generation_ms"], 2000);
}

#[test]
fn fix2_codex_revision_revokes_previous_cross_window_timings() {
    assert_eq!(adapters::parser_rev("codex"), 5);
    let db = ledger();
    let mut old = parse(&[usage(8, "resp_abcdef0123456789")]).remove(0);
    old["timing"]["ttft_ms"] = json!(1000);
    old["timing"]["ttft_method"] = json!("log_timestamps");
    old["timing"]["generation_ms"] = json!(2000);
    old["timing"]["generation_method"] = json!("log_timestamps");
    db.batch_with_timing_revision(&[old], Some("log"), Some(5), Some(1), &[], pricing::cost_of)
        .unwrap();
    let new = parse(&[usage(8, "resp_abcdef0123456789")]);
    db.batch_with_timing_revision(
        &new,
        Some("log"),
        Some(adapters::parser_rev("codex")),
        Some(2),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let summary = db.timing_summary(&json!({})).unwrap();
    assert!(summary["ttft"].is_null() && summary["speed"].is_null());
}
