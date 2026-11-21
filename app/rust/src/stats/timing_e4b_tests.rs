use super::{
    adapters,
    clock::Clock,
    jscompat::LocalZone,
    ledger::{rows, Ledger},
    pricing,
};
use rusqlite::Connection;
use serde_json::{json, Value};

fn parse(source: &str, objects: &[Value]) -> Vec<Value> {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("updates.jsonl");
    std::fs::write(
        &file,
        objects
            .iter()
            .map(|v| v.to_string() + "\n")
            .collect::<String>(),
    )
    .unwrap();
    adapters::parse(source, "test.jsonl", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0
}

fn fix1_claude_request() -> Value {
    json!({"type":"api-request","id":"req","timestamp":"2026-01-15T00:00:00Z"})
}
fn fix1_claude_block(second: u8, stop: Value) -> Value {
    json!({"type":"assistant","sessionId":"s","requestRef":"req","timestamp":format!("2026-01-15T00:00:{second:02}Z"),"message":{"role":"assistant","id":"msg_a","stop_reason":stop,"usage":{"input_tokens":10,"output_tokens":20}}})
}

#[test]
fn timing2_claude_thinking_ttft_uses_duration_start() {
    for (index, kind, thinking, ttft) in [
        (json!(0), "thinking", json!(600), json!(400)),
        (json!(0), "thinking", Value::Null, Value::Null),
        (json!(0), "thinking", json!(1000), Value::Null),
        (json!(0), "thinking", json!(1001), Value::Null),
        (json!(0), "thinking", json!(0), Value::Null),
        (json!(0), "thinking", json!(-10), Value::Null),
        (json!(0), "thinking", json!("600"), Value::Null),
        (json!(2), "thinking", json!(600), Value::Null),
        (Value::Null, "thinking", json!(600), Value::Null),
        (json!(0), "text", json!(600), Value::Null),
    ] {
        let mut first = fix1_claude_block(1, Value::Null);
        first["apiBlockIndex"] = index;
        first["message"]["content"] = json!([{"type":kind}]);
        first["thinkingDurationMs"] = thinking;
        let mut last = fix1_claude_block(3, json!("end_turn"));
        last["apiBlockIndex"] = json!(3);
        last["message"]["content"] = json!([{"type":"thinking"}]);
        last["thinkingDurationMs"] = json!(500);
        let record = &parse("claude", &[fix1_claude_request(), first, last])[0];
        let timing = &record["timing"];
        assert_eq!(timing["duration_ms"], 3000);
        assert_eq!(timing["ttft_ms"], ttft);
        assert_eq!(
            timing["ttft_method"],
            json!((!ttft.is_null()).then_some("log_timestamps"))
        );
        assert!(timing["generation_ms"].is_null());
    }
}

#[test]
fn timing2_claude_thinking_requires_an_unambiguous_window() {
    let mut first = fix1_claude_block(3, Value::Null);
    first["apiBlockIndex"] = json!(0);
    first["message"]["content"] = json!([{"type":"thinking"}]);
    first["thinkingDurationMs"] = json!(1000);
    first["message"]["usage"] = Value::Null;
    let last = fix1_claude_block(2, json!("end_turn"));
    let request = fix1_claude_request();
    let records = parse("claude", &[request.clone(), first.clone(), last.clone()]);
    assert_eq!(records[0]["timing"]["ttft_ms"], 2000);
    assert_eq!(records[0]["timing"]["duration_ms"], 2000);

    for (input, duration) in [
        (vec![first.clone(), last.clone()], Value::Null),
        (
            vec![
                request.clone(),
                request.clone(),
                first.clone(),
                last.clone(),
            ],
            Value::Null,
        ),
        (
            vec![request.clone(), first.clone(), first.clone(), last],
            json!(2000),
        ),
        (
            vec![request, first, fix1_claude_block(1, json!("end_turn"))],
            json!(1000),
        ),
    ] {
        let records = parse("claude", &input);
        assert_eq!(records[0]["timing"]["duration_ms"], duration);
        assert!(records[0]["timing"]["ttft_ms"].is_null());
    }
}

#[test]
fn e4b_fix1_claude_incremental_same_usage_grows_until_completed() {
    let db = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let first = parse(
        "claude",
        &[fix1_claude_request(), fix1_claude_block(1, Value::Null)],
    );
    db.batch(
        &first,
        Some("log"),
        Some(adapters::parser_rev("claude")),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let usage = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    let timing = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
    assert_eq!(timing[0]["duration_ms"], 1000);
    assert_eq!(timing[0]["status"], "partial");
    assert!(db.timing_summary(&json!({})).unwrap()["throughput"].is_null());
    let complete = parse(
        "claude",
        &[
            fix1_claude_request(),
            fix1_claude_block(1, Value::Null),
            fix1_claude_block(3, json!("end_turn")),
        ],
    );
    for _ in 0..2 {
        db.batch(
            &complete,
            Some("log"),
            Some(adapters::parser_rev("claude")),
            &[],
            pricing::cost_of,
        )
        .unwrap();
        assert_eq!(
            rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
            usage
        );
        let timing = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
        assert_eq!(timing[0]["duration_ms"], 3000);
        assert_eq!(timing[0]["status"], "completed");
        let summary = db.timing_summary(&json!({})).unwrap();
        assert_eq!(summary["request_count"], 1);
        assert_eq!(summary["throughput"][0]["sample_count"], 1);
        let rate = summary["throughput"][0]["tokens_per_second"]
            .as_f64()
            .unwrap();
        assert!((rate - 20_000.0 / 3000.0).abs() < 1e-10);
        assert_eq!(format!("{rate:.2}"), "6.67");
    }
}

#[test]
fn e4b_fix1_claude_terminal_evidence_keeps_completed_group_immutable() {
    for reason in ["end_turn", "tool_use", "max_tokens"] {
        let db = Ledger::open(
            std::path::Path::new(":memory:"),
            Clock::Fixed(1768435200000),
        )
        .unwrap();
        let pending = parse(
            "claude",
            &[fix1_claude_request(), fix1_claude_block(1, Value::Null)],
        );
        assert_eq!(pending[0]["timing"]["status"], "partial");
        let completed = parse(
            "claude",
            &[fix1_claude_request(), fix1_claude_block(1, json!(reason))],
        );
        assert_eq!(completed[0]["timing"]["status"], "completed");
        db.batch(&completed, Some("log"), Some(3), &[], pricing::cost_of)
            .unwrap();
        let old = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
        let later = parse(
            "claude",
            &[
                fix1_claude_request(),
                fix1_claude_block(1, json!(reason)),
                fix1_claude_block(3, json!(reason)),
            ],
        );
        assert_eq!(later[0]["timing"]["duration_ms"], 3000);
        db.batch(&later, Some("log"), Some(3), &[], pricing::cost_of)
            .unwrap();
        assert_eq!(
            rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap(),
            old
        );
        assert_eq!(
            db.timing_summary(&json!({})).unwrap()["throughput"][0]["tokens_per_second"],
            20.0
        );
    }
}

#[test]
fn e4b_fix1_claude_completion_uses_last_valid_usage_block_only() {
    for stop in [
        Value::Null,
        json!(""),
        json!(" \t"),
        json!(1),
        json!({}),
        json!(false),
    ] {
        let mut later = fix1_claude_block(3, stop);
        later["message"]["stopReason"] = json!("end_turn");
        let r = parse(
            "claude",
            &[
                fix1_claude_request(),
                fix1_claude_block(1, json!("end_turn")),
                later,
            ],
        );
        assert_eq!(r[0]["timing"]["status"], "partial");
        assert_eq!(r[0]["timing"]["duration_ms"], 3000);
    }
    let mut zero = fix1_claude_block(3, json!("end_turn"));
    zero["message"]["usage"] = json!({"input_tokens":0,"output_tokens":0});
    let r = parse(
        "claude",
        &[
            fix1_claude_request(),
            fix1_claude_block(1, Value::Null),
            zero,
            json!({"type":"user","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}),
        ],
    );
    assert_eq!(r[0]["timing"]["status"], "partial");
    assert_eq!(r[0]["timing"]["duration_ms"], 1000);
    let mut missing = fix1_claude_block(1, Value::Null);
    missing["message"]
        .as_object_mut()
        .unwrap()
        .remove("stop_reason");
    assert_eq!(
        parse("claude", &[fix1_claude_request(), missing])[0]["timing"]["status"],
        "partial"
    );
}

#[test]
fn e4b_fix1_claude_timing_revision_replaces_old_completed_without_changing_usage() {
    assert_eq!(adapters::timing_rev("claude"), Some(3));
    assert_eq!(adapters::parser_rev("claude"), 3);
    let db = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let input = [fix1_claude_request(), fix1_claude_block(1, Value::Null)];
    let current = parse("claude", &input);
    let mut old = current.clone();
    old[0]["timing"]["status"] = json!("completed");
    db.batch_with_timing_revision(&old, Some("log"), Some(3), Some(1), &[], pricing::cost_of)
        .unwrap();
    let before = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    db.batch(&current, Some("log"), Some(3), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
        before
    );
    let timing = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
    assert_eq!(timing[0]["parser_rev"], 3);
    assert_eq!(timing[0]["status"], "partial");
    assert!(db.timing_summary(&json!({})).unwrap()["throughput"].is_null());
}
#[test]
fn e4b_qwen_duration_missing_invalid_and_usage_unchanged() {
    for (value, want) in [
        (json!(1250), json!(1250)),
        (Value::Null, Value::Null),
        (json!(0), Value::Null),
        (json!(-1), Value::Null),
        (json!("20"), Value::Null),
    ] {
        let obj = json!({"id":"a","sessionId":"s","timestamp":"2026-01-15T00:00:00Z","inputTokens":10,"outputTokens":20,"apiDurationMs":value});
        let r = parse("qwen", &[obj]);
        assert_eq!(r[0]["timing"]["duration_ms"], want);
        assert_eq!(r[0]["timing"]["scope"], "request");
        assert_eq!(r[0]["output_tokens"], 20);
        assert!(r[0]["timing"]["generation_ms"].is_null());
    }
}
#[test]
fn e4b_pi_duration_priority_fallback_and_failed_status() {
    for (duration, end, want, method) in [
        (
            json!(1200),
            "2026-01-15T00:00:02Z",
            json!(1200),
            json!("client_reported"),
        ),
        (
            Value::Null,
            "2026-01-15T00:00:02Z",
            json!(2000),
            json!("log_timestamps"),
        ),
        (json!(0), "2026-01-15T00:00:02Z", Value::Null, Value::Null),
        (json!(-1), "2026-01-15T00:00:02Z", Value::Null, Value::Null),
        (
            Value::Null,
            "2026-01-15T00:00:00Z",
            Value::Null,
            Value::Null,
        ),
    ] {
        let mut obj = json!({"type":"message","id":"a","timestamp":end,"message":{"role":"assistant","timestamp":1768435200000_i64,"usage":{"input":10,"output":20},"stopReason":"stop"}});
        if !duration.is_null() {
            obj["message"]["durationMs"] = duration;
        }
        let r = parse("pi", &[obj.clone()]);
        assert_eq!(r[0]["timing"]["duration_ms"], want);
        assert_eq!(r[0]["timing"]["duration_method"], method);
        assert_eq!(r[0]["timing"]["status"], "completed");
        obj["message"]["stopReason"] = json!("error");
        assert_eq!(parse("pi", &[obj])[0]["timing"]["status"], "failed");
    }
}
fn db_parse(source: &str, data: Value) -> Vec<Value> {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("source.db");
    let db = Connection::open(&file).unwrap();
    if source == "anythingllm" {
        db.execute_batch("CREATE TABLE workspace_chats(id INTEGER,workspaceId INTEGER,response TEXT,createdAt INTEGER);").unwrap();
        db.execute(
            "INSERT INTO workspace_chats VALUES(1,1,?,1768435200000)",
            [data.to_string()],
        )
        .unwrap();
    } else {
        db.execute_batch("CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);CREATE TABLE session(id TEXT,directory TEXT);CREATE TABLE session_v2(id TEXT,directory TEXT);").unwrap();
        db.execute(
            "INSERT INTO session_message VALUES('a','s','assistant',1768435200000,1768435204000,?)",
            [data.to_string()],
        )
        .unwrap();
    }
    drop(db);
    adapters::parse(source, "source.db", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0
}
#[test]
fn e4b_opencode_mimo_kilo_three_metrics_and_invalid_windows() {
    for source in ["opencode", "mimo", "kilo"] {
        for (end, first, ttft, generation, duration) in [
            (
                json!(1768435204000_i64),
                json!(1768435201000_i64),
                json!(1000),
                json!(3000),
                json!(4000),
            ),
            (
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
            ),
            (
                json!(1768435200000_i64),
                json!(1768435200000_i64),
                Value::Null,
                Value::Null,
                Value::Null,
            ),
        ] {
            let data = json!({"time":{"created":1768435200000_i64,"completed":end},"tokens":{"input":10,"output":20,"reasoning":5},"content":[{"type":"reasoning","time":{"created":first}},{"type":"text","time":{"created":1768435200001_i64}}]});
            let r = db_parse(source, data);
            assert_eq!(
                r[0]["timing"]["ttft_ms"], ttft,
                "{source}: {:?}",
                r[0]["timing"]
            );
            assert_eq!(r[0]["timing"]["generation_ms"], generation);
            assert_eq!(r[0]["timing"]["duration_ms"], duration);
            assert_eq!(r[0]["output_tokens"], 25);
            if !ttft.is_null() {
                assert_eq!(r[0]["timing"]["ttft_method"], "content_event_proxy");
                assert_eq!(r[0]["timing"]["duration_method"], "log_timestamps");
            }
        }
    }
}
#[test]
fn e4b_anythingllm_seconds_missing_zero_and_negative() {
    for (seconds, want) in [
        (json!(1.25), json!(1250)),
        (Value::Null, Value::Null),
        (json!(0), Value::Null),
        (json!(-1), Value::Null),
    ] {
        let r = db_parse(
            "anythingllm",
            json!({"metrics":{"prompt_tokens":10,"completion_tokens":20,"duration":seconds}}),
        );
        assert_eq!(r[0]["timing"]["duration_ms"], want);
        assert_eq!(r[0]["timing"]["scope"], "request");
    }
}
#[test]
fn e4b_openhands_seconds_unique_response_only() {
    for (latencies, want) in [
        (json!([{"response_id":"r","latency":1.25}]), json!(1250)),
        (json!([]), Value::Null),
        (json!([{"response_id":"r","latency":0}]), Value::Null),
        (json!([{"response_id":"r","latency":-1}]), Value::Null),
        (
            json!([{"response_id":"r","latency":1},{"response_id":"r","latency":2}]),
            Value::Null,
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("events")).unwrap();
        std::fs::write(
            dir.path().join("events/event-00001-abcdef12.json"),
            json!({"llm_response_id":"r","timestamp":"2026-01-15T00:00:01Z"}).to_string(),
        )
        .unwrap();
        let file = dir.path().join("base_state.json");
        std::fs::write(&file,json!({"id":"s","agent":{"kind":"Agent"},"stats":{"usage_to_metrics":{"m":{"token_usages":[{"response_id":"r","prompt_tokens":10,"completion_tokens":20,"cache_read_tokens":0,"cache_write_tokens":0}],"response_latencies":latencies}}}}).to_string()).unwrap();
        let r = adapters::parse("openhands", "base_state.json", &file, &LocalZone::Fixed(0))
            .unwrap()
            .0;
        assert_eq!(r[0]["timing"]["duration_ms"], want);
        assert_eq!(r[0]["timing"]["scope"], "request");
    }
}
#[test]
fn e4b_claude_request_ref_last_valid_usage_and_ambiguity() {
    let req = json!({"type":"api-request","id":"req","timestamp":"2026-01-15T00:00:00Z"});
    let msg = |time: &str, reference: &str| json!({"type":"assistant","requestRef":reference,"timestamp":time,"message":{"id":"msg_a","usage":{"input_tokens":10,"output_tokens":20}}});
    let r = parse(
        "claude",
        &[
            req.clone(),
            msg("2026-01-15T00:00:01Z", "req"),
            msg("2026-01-15T00:00:03Z", "req"),
        ],
    );
    assert_eq!(r[0]["timing"]["duration_ms"], 3000);
    assert_eq!(r[0]["observed_at"], "2026-01-15T00:00:01.000Z");
    for input in [
        vec![msg("2026-01-15T00:00:03Z", "missing")],
        vec![req.clone(), msg("2026-01-15T00:00:00Z", "req")],
        vec![req.clone(), req.clone(), msg("2026-01-15T00:00:03Z", "req")],
        vec![
            req,
            msg("2026-01-15T00:00:01Z", "req"),
            msg("2026-01-15T00:00:03Z", "other"),
        ],
    ] {
        assert!(parse("claude", &input)[0]["timing"]["duration_ms"].is_null());
    }
}

#[test]
fn e4b_claude_shared_request_ref_or_missing_message_id_has_no_duration() {
    let req = json!({"type":"api-request","id":"req","timestamp":"2026-01-15T00:00:00Z"});
    let msg = |id: Value| json!({"type":"assistant","requestRef":"req","timestamp":"2026-01-15T00:00:01Z","message":{"id":id,"usage":{"input_tokens":10,"output_tokens":20}}});
    for input in [
        vec![req.clone(), msg(json!("msg_a")), msg(json!("msg_b"))],
        vec![req, msg(Value::Null)],
    ] {
        let r = parse("claude", &input);
        for record in r {
            assert!(record["timing"]["duration_ms"].is_null());
            assert_eq!(record["output_tokens"], 20);
        }
    }
}

#[test]
fn e4b_missing_reasoning_start_does_not_borrow_a_later_content_start() {
    for source in ["opencode", "mimo", "kilo"] {
        let r = db_parse(
            source,
            json!({"time":{"created":1768435200000_i64,"completed":1768435204000_i64},"tokens":{"input":10,"output":20},"content":[{"type":"reasoning"},{"type":"reasoning","time":{"created":1768435202000_i64}}]}),
        );
        assert!(r[0]["timing"]["ttft_ms"].is_null());
        assert!(r[0]["timing"]["generation_ms"].is_null());
        assert_eq!(r[0]["timing"]["duration_ms"], 4000);
    }
}
fn grok(kind: &str, time: i64, extra: Value) -> Value {
    let mut u = json!({"sessionUpdate":kind});
    for (k, v) in extra.as_object().unwrap() {
        u[k] = v.clone();
    }
    json!({"params":{"sessionId":"s","_meta":{"agentTimestampMs":time},"update":u}})
}
#[test]
fn e4b_grok_turn_scope_first_content_and_reset() {
    let r = parse(
        "grok",
        &[
            grok(
                "user_message_chunk",
                1000,
                json!({"content":{"type":"text","text":"a"}}),
            ),
            grok(
                "agent_message_chunk",
                1100,
                json!({"content":{"type":"text","text":""}}),
            ),
            grok(
                "agent_message_chunk",
                2345,
                json!({"content":{"type":"text","text":"b"}}),
            ),
            grok(
                "turn_completed",
                4000,
                json!({"turnId":"a","usage":{"inputTokens":10,"outputTokens":20,"apiDurationMs":3000}}),
            ),
            grok(
                "turn_completed",
                5000,
                json!({"turnId":"b","usage":{"outputTokens":20,"apiDurationMs":0}}),
            ),
        ],
    );
    assert_eq!(r[0]["timing"]["ttft_ms"], 1345);
    assert_eq!(r[0]["timing"]["scope"], "turn");
    assert_eq!(r[0]["timing"]["duration_ms"], 3000);
    assert!(r[1]["timing"]["ttft_ms"].is_null());
    assert!(r[1]["timing"]["duration_ms"].is_null());
}
#[test]
fn e4b_throughput_sum_coverage_turn_separation_and_usage_invariants() {
    let db = Ledger::open(std::path::Path::new(":memory:"), Clock::System).unwrap();
    let mut records = parse(
        "qwen",
        &[
            json!({"id":"a","sessionId":"s","outputTokens":100,"apiDurationMs":1000}),
            json!({"id":"b","sessionId":"s","outputTokens":900,"apiDurationMs":9000}),
            json!({"id":"c","sessionId":"s","outputTokens":10}),
        ],
    );
    let turn = parse(
        "grok",
        &[
            grok("user_message_chunk", 1000, json!({"content":{"text":"a"}})),
            grok("agent_message_chunk", 2000, json!({"content":{"text":"b"}})),
            grok(
                "turn_completed",
                4000,
                json!({"usage":{"outputTokens":500,"apiDurationMs":1000}}),
            ),
        ],
    );
    records.extend(turn);
    for r in &mut records {
        r["observed_at"] = json!("2026-01-15T00:00:00Z");
    }
    db.batch(&records, Some("log"), Some(1), &[], pricing::cost_of)
        .unwrap();
    let summary = db.timing_summary(&json!({})).unwrap();
    assert_eq!(summary["request_count"], 3);
    assert_eq!(summary["throughput"][0]["sample_count"], 2);
    assert_eq!(summary["throughput"][0]["tokens_per_second"], 100.0);
    assert!(summary["ttft"].is_null());
    assert_eq!(summary["turn"]["turn_count"], 1);
    assert_eq!(summary["turn"]["throughput"][0]["tokens_per_second"], 500.0);
    let usage = rows(
        &db.db,
        "SELECT * FROM usage_records ORDER BY record_key",
        &[],
    )
    .unwrap();
    db.batch(&records, Some("log"), Some(1), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        rows(
            &db.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[]
        )
        .unwrap(),
        usage
    );
    assert_eq!(
        rows(
            &db.db,
            "SELECT sum(output_tokens) AS n FROM usage_records",
            &[]
        )
        .unwrap()[0]["n"],
        1510
    );
}

#[test]
fn e4b_duration_group_retention_replacement_and_hash() {
    let db = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let mut r=parse("qwen",&[json!({"id":"a","timestamp":"2026-01-15T00:00:00Z","outputTokens":100,"apiDurationMs":1000})]).remove(0);
    r["timing"]["status"] = json!("partial");
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("a"),
        Some(7),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let usage = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    let old = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
    let mut missing = r.clone();
    missing["timing"]["duration_ms"] = Value::Null;
    missing["timing"]["duration_method"] = Value::Null;
    missing["timing"]["ttft_ms"] = json!(10);
    missing["timing"]["ttft_method"] = json!("log_timestamps");
    db.batch_with_timing_revision(
        &[missing.clone()],
        Some("a"),
        Some(7),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap(),
        old
    );
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
        usage
    );
    r["timing"]["duration_ms"] = json!(2000);
    r["timing"]["status"] = json!("completed");
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("a"),
        Some(7),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let completed = rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap();
    assert_ne!(old[0]["timing_hash"], completed[0]["timing_hash"]);
    r["timing"]["duration_ms"] = json!(100);
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("a"),
        Some(7),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_timings", &[]).unwrap(),
        completed
    );
    db.batch_with_timing_revision(
        &[missing.clone()],
        Some("b"),
        Some(7),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert!(
        rows(&db.db, "SELECT duration_ms FROM usage_timings", &[]).unwrap()[0]["duration_ms"]
            .is_null()
    );
    r["output_tokens"] = json!(200);
    r["timing"]["timing_output_tokens"] = json!(200);
    db.batch_with_timing_revision(&[r], Some("b"), Some(7), Some(1), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        db.timing_summary(&json!({})).unwrap()["throughput"][0]["tokens_per_second"],
        2000.0
    );
    db.batch_with_timing_revision(
        &[missing],
        Some("b"),
        Some(7),
        Some(2),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    assert!(db.timing_summary(&json!({})).unwrap()["throughput"].is_null());
}

#[test]
fn e4b_throughput_status_unknown_zero_output_filters_and_method_coverage() {
    let db = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let mut records = Vec::new();
    for (id, status, output) in [
        ("ok", "completed", json!(0)),
        ("failed", "failed", json!(900)),
        ("cancelled", "cancelled", json!(900)),
        ("partial", "partial", json!(900)),
        ("unknown", "unknown", json!(900)),
        ("missing", "completed", Value::Null),
    ] {
        records.push(json!({"record_key":id,"source":"pi","session_id":"s","project_key":"p","model":"m","kind":"event","observed_at":"2026-01-15T00:00:00Z","input_tokens":1,"output_tokens":output,"timing":{"scope":"request","status":status,"duration_ms":1000,"duration_method":"client_reported","timing_output_tokens":output}}));
    }
    let mut other = records[0].clone();
    other["record_key"] = json!("other");
    other["source"] = json!("qwen");
    other["model"] = json!("else");
    records.push(other);
    db.batch(&records, Some("a"), Some(1), &[], pricing::cost_of)
        .unwrap();
    let filter = json!({"source":"pi","session":"s","project":"p","model":"m","from":"2026-01-15","to":"2026-01-15"});
    let t = db.timing_summary(&filter).unwrap();
    assert_eq!(t["request_count"], 6);
    assert_eq!(t["throughput"][0]["sample_count"], 1);
    assert_eq!(t["throughput"][0]["tokens_per_second"], 0.0);
    db.db
        .execute(
            "UPDATE usage_records SET active=0 WHERE record_key='ok'",
            [],
        )
        .unwrap();
    let t = db.timing_summary(&filter).unwrap();
    assert_eq!(t["request_count"], 5);
    assert!(t["throughput"].is_null());
    assert_eq!(
        db.timing_summary(&json!({"source":"absent"})).unwrap()["request_count"],
        0
    );
}

#[test]
fn e4b_timing_preserves_usage_hashes_money_and_group_sums() {
    let a = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let b = Ledger::open(
        std::path::Path::new(":memory:"),
        Clock::Fixed(1768435200000),
    )
    .unwrap();
    let mut records = parse(
        "qwen",
        &[
            json!({"id":"a","timestamp":"2026-01-15T00:00:00Z","model":"claude-opus-5-5","inputTokens":100,"outputTokens":100,"cachedTokens":0,"cacheWriteTokens":0,"apiDurationMs":1000}),
            json!({"id":"b","timestamp":"2026-01-15T00:00:00Z","model":"claude-opus-5-5","inputTokens":100,"outputTokens":900,"cachedTokens":0,"cacheWriteTokens":0,"apiDurationMs":9000}),
        ],
    );
    let baseline: Vec<_> = records
        .iter()
        .cloned()
        .map(|mut r| {
            r.as_object_mut().unwrap().remove("timing");
            r
        })
        .collect();
    a.batch(&baseline, Some("a"), Some(7), &[], pricing::cost_of)
        .unwrap();
    b.batch(&records, Some("a"), Some(7), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        rows(
            &a.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[]
        )
        .unwrap(),
        rows(
            &b.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[]
        )
        .unwrap()
    );
    let total = b.totals(&json!({})).unwrap();
    assert!(total["cost_micros"].as_i64().unwrap() > 0);
    for by in ["source", "model", "source_model"] {
        let groups = if by == "source_model" {
            b.grouped("source", "model", &json!({})).unwrap()
        } else {
            b.breakdown(by, &json!({})).unwrap()
        };
        for field in [
            "input_tokens",
            "output_tokens",
            "cost_micros",
            "record_count",
        ] {
            let sum: i64 = groups.iter().map(|r| r[field].as_i64().unwrap()).sum();
            assert_eq!(sum, total[field]);
        }
    }
    for r in &mut records {
        r["timing"]["duration_ms"] = json!(2000);
    }
    b.batch_with_timing_revision(&records, Some("a"), Some(7), Some(2), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(a.totals(&json!({})).unwrap(), b.totals(&json!({})).unwrap());
}
