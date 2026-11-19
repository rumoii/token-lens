use super::{
    adapters,
    clock::Clock,
    jscompat::LocalZone,
    ledger::{rows, Ledger},
    pricing, service,
};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::path::Path;

fn parse(source: &str, text: &[Value]) -> Vec<Value> {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("wire.jsonl");
    std::fs::write(
        &file,
        text.iter()
            .map(|v| v.to_string() + "\n")
            .collect::<String>(),
    )
    .unwrap();
    adapters::parse(
        source,
        "sessions/p/session_s/agents/a/wire.jsonl",
        &file,
        &LocalZone::Fixed(0),
    )
    .unwrap()
    .0
}
fn usage(at: &str, id: &str) -> Value {
    json!({"type":"token_usage_record","timestamp":at,"payload":{"session_id":"s","response_id":id,"usage":{"input_tokens":10,"output_tokens":20}}})
}
fn boundary(kind: &str, at: &str) -> Value {
    json!({"type":"event_msg","timestamp":at,"payload":{"type":kind}})
}
fn first(kind: &str, start: Value) -> Value {
    let end = start.as_i64().and_then(|start| start.checked_add(500));
    json!({"type":"event_msg","timestamp":"2026-01-15T00:00:02.000Z","payload":{"type":"item_completed","started_at_ms":start,"completed_at_ms":end,"item":{"type":kind}}})
}
const START: &str = "2026-01-15T00:00:00.000Z";
const END: &str = "2026-01-15T00:00:04.000Z";
const MS: i64 = 1768435202000;

pub(crate) fn strip_golden_timing(value: &mut Value) {
    if let Some(object) = value.as_object_mut() {
        for key in ["timing", "model_timing"] {
            if let Some(timing) = object.remove(key) {
                assert!(
                    timing["ttft"].is_null()
                        && timing["speed"].is_null()
                        && timing["throughput"].is_null()
                        && timing["turn"]["ttft"].is_null()
                        && timing["turn"]["speed"].is_null()
                        && timing["turn"]["throughput"].is_null(),
                    "Node fixture unexpectedly gained timing evidence"
                );
                if key == "timing" {
                    let n = if object.contains_key("session") {
                        object["period"]["request_count"].as_i64().unwrap_or(0)
                    } else {
                        object
                            .get("request_count")
                            .and_then(Value::as_i64)
                            .unwrap_or(0)
                    };
                    assert_eq!(
                        timing["request_count"].as_i64().unwrap()
                            + timing["turn"]["turn_count"].as_i64().unwrap_or(0),
                        n
                    );
                }
            }
        }
        for child in object.values_mut() {
            strip_golden_timing(child);
        }
    } else if let Some(items) = value.as_array_mut() {
        for item in items {
            strip_golden_timing(item);
        }
    }
}

#[test]
fn e4_codex_content_before_usage_and_developer_is_not_boundary() {
    let result = parse(
        "codex",
        &[
            boundary("task_started", START),
            json!({"type":"response_item","timestamp":"2026-01-15T00:00:01Z","payload":{"type":"message","role":"developer"}}),
            first("Reasoning", json!(MS)),
            first("AgentMessage", json!(MS + 500)),
            usage(END, "resp_abcdef0123456789"),
        ],
    );
    assert_eq!(result[0]["timing"]["ttft_ms"], 2000);
    assert_eq!(result[0]["timing"]["generation_ms"], 2000);
    assert_eq!(result[0]["timing"]["timing_output_tokens"], 20);
    assert_eq!(result[0]["timing"]["ttft_method"], "log_timestamps");
}

#[test]
fn e4_codex_user_item_and_tool_result_messages_are_boundaries() {
    let boundaries = [
        json!({"type":"event_msg","timestamp":"2026-01-15T00:00:01.000Z","payload":{"type":"item_completed","item":{"type":"UserMessage"}}}),
        json!({"type":"response_item","timestamp":"2026-01-15T00:00:01.000Z","payload":{"type":"function_call_output"}}),
        json!({"type":"response_item","timestamp":"2026-01-15T00:00:01.000Z","payload":{"type":"custom_tool_call_output"}}),
    ];
    for b in boundaries {
        let r = parse(
            "codex",
            &[
                boundary("task_started", START),
                b,
                first("Reasoning", json!(MS)),
                usage(END, "resp_abcdef0123456789"),
            ],
        );
        assert_eq!(r[0]["timing"]["ttft_ms"], 1000);
    }
}

#[test]
fn e4_codex_tools_and_old_logs_have_no_first_output() {
    for kind in ["CommandExecution", "McpToolCall", "FileChange", "Reasoning"] {
        let start = if kind == "Reasoning" {
            Value::Null
        } else {
            json!(MS)
        };
        let r = parse(
            "codex",
            &[
                boundary("task_started", START),
                first(kind, start),
                usage(END, "resp_abcdef0123456789"),
            ],
        );
        assert!(r[0]["timing"]["ttft_ms"].is_null());
        assert!(r[0]["timing"]["generation_ms"].is_null());
        assert_eq!(r[0]["timing"]["scope"], "request");
    }
}
#[test]
fn e4_codex_abort_new_turn_and_previous_request_clear_state() {
    for clear in ["turn_aborted", "task_started", "turn_started"] {
        let r = parse(
            "codex",
            &[
                boundary("task_started", START),
                first("Reasoning", json!(MS)),
                boundary(clear, "2026-01-15T00:00:03Z"),
                usage(END, "resp_abcdef0123456789"),
            ],
        );
        assert!(r[0]["timing"]["ttft_ms"].is_null());
        assert!(r[0]["timing"]["generation_ms"].is_null());
    }
    let r = parse(
        "codex",
        &[
            boundary("task_started", START),
            first("Reasoning", json!(MS)),
            usage(END, "resp_abcdef0123456789"),
            usage(END, "resp_abcdef0123456780"),
        ],
    );
    assert!(r[1]["timing"]["ttft_ms"].is_null());
}
#[test]
fn e4_codex_nonpositive_differences_are_null_independently() {
    let r = parse(
        "codex",
        &[
            boundary("task_started", END),
            first("Reasoning", json!(MS)),
            usage(END, "resp_abcdef0123456789"),
        ],
    );
    assert!(r[0]["timing"]["ttft_ms"].is_null());
    assert!(r[0]["timing"]["generation_ms"].is_null());
    let r = parse(
        "codex",
        &[
            first("Reasoning", json!(MS)),
            usage(END, "resp_abcdef0123456789"),
        ],
    );
    assert!(r[0]["timing"]["ttft_ms"].is_null());
    assert_eq!(r[0]["timing"]["generation_ms"], 2000);
    let r = parse(
        "codex",
        &[
            boundary("task_started", START),
            first("Reasoning", json!(MS + 2000)),
            usage(END, "resp_abcdef0123456789"),
        ],
    );
    assert!(r[0]["timing"]["generation_ms"].is_null());
}
#[test]
fn e4_kimi_matches_unique_usage_and_independent_missing_or_negative_fields() {
    for (latency, duration, want_l, want_d) in [
        (json!(200), json!(500), json!(200), json!(500)),
        (Value::Null, json!(500), Value::Null, json!(500)),
        (json!(200), Value::Null, json!(200), Value::Null),
        (json!(-1), json!(-2), Value::Null, Value::Null),
    ] {
        let r = parse(
            "kimi",
            &[
                json!({"type":"context.append_loop_event","event":{"type":"step.begin","step":1}}),
                json!({"type":"usage.record","time":1768435201000_i64,"usage":{"inputOther":10,"output":20,"inputCacheRead":0,"inputCacheCreation":0}}),
                json!({"type":"context.append_loop_event","event":{"type":"step.end","step":1,"finishReason":"end_turn","usage":{"inputOther":10,"output":20,"inputCacheRead":0,"inputCacheCreation":0},"llmFirstTokenLatencyMs":latency,"llmStreamDurationMs":duration}}),
            ],
        );
        assert_eq!(r[0]["timing"]["ttft_ms"], want_l);
        assert_eq!(r[0]["timing"]["generation_ms"], want_d);
        assert_eq!(r[0]["timing"]["status"], "completed");
    }
}
#[test]
fn e4_zcode_synthetic_schema_native_fallback_status_and_missing_columns() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("zcode.db");
    let db = Connection::open(&file).unwrap();
    db.execute_batch("CREATE TABLE model_usage(id TEXT,session_id TEXT,model_id TEXT,provider_id TEXT,started_at INTEGER,input_tokens INTEGER,output_tokens INTEGER,cache_read_input_tokens INTEGER,cache_creation_input_tokens INTEGER,first_token_at INTEGER,completed_at INTEGER,time_to_first_token_ms INTEGER,status TEXT); INSERT INTO model_usage VALUES ('a','s','m','p',1768435200000,10,20,0,0,1768435200100,1768435200600,200,'completed'),('b','s','m','p',1768435201000,10,20,0,0,1768435201100,1768435201600,NULL,'error'),('c','s','m','p',1768435202000,10,20,0,0,NULL,NULL,-1,'cancelled')").unwrap();
    let r = adapters::parse("zcode", "zcode.db", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0;
    assert_eq!(r[0]["timing"]["ttft_ms"], 200);
    assert_eq!(r[0]["timing"]["generation_ms"], 500);
    assert_eq!(r[0]["timing"]["status"], "completed");
    assert_eq!(r[1]["timing"]["ttft_ms"], 100);
    assert_eq!(r[1]["timing"]["status"], "failed");
    assert!(r[2]["timing"]["ttft_ms"].is_null());
    assert_eq!(r[2]["timing"]["status"], "cancelled");
    db.execute_batch("ALTER TABLE model_usage DROP COLUMN first_token_at; ALTER TABLE model_usage DROP COLUMN completed_at; ALTER TABLE model_usage DROP COLUMN time_to_first_token_ms; ALTER TABLE model_usage DROP COLUMN status;").unwrap();
    let r = adapters::parse("zcode", "zcode.db", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0;
    assert_eq!(r[0]["timing"]["status"], "unknown");
    assert!(r[0]["timing"]["generation_ms"].is_null());
}

#[test]
fn e4_zcode_zero_millisecond_fallback_is_known_but_not_speed_sample() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("zcode.db");
    Connection::open(&file).unwrap().execute_batch("CREATE TABLE model_usage(id TEXT,session_id TEXT,model_id TEXT,provider_id TEXT,started_at INTEGER,input_tokens INTEGER,output_tokens INTEGER,cache_read_input_tokens INTEGER,cache_creation_input_tokens INTEGER,first_token_at INTEGER,completed_at INTEGER,status TEXT); INSERT INTO model_usage VALUES ('a','s','m','p',1768435200000,10,20,0,0,1768435200000,1768435200000,'completed')").unwrap();
    let r = adapters::parse("zcode", "zcode.db", &file, &LocalZone::Fixed(0))
        .unwrap()
        .0;
    assert_eq!(r[0]["timing"]["ttft_ms"], 0);
    assert_eq!(r[0]["timing"]["generation_ms"], 0);
    let db = ledger();
    db.batch(&r, None, Some(2), &[], pricing::cost_of).unwrap();
    let t = db.timing_summary(&json!({})).unwrap();
    assert_eq!(t["ttft"][0]["median_ms"], 0);
    assert!(t["speed"].is_null());
}
fn record(id: &str, ttft: i64, output: i64, duration: i64) -> Value {
    json!({"record_key":id,"source":"kimi","session_id":"s","model":"m","project_key":"p","observed_at":START,"kind":"event","input_tokens":10,"output_tokens":output,
    "timing":{"ttft_ms":ttft,"ttft_method":"client_reported","generation_ms":duration,"generation_method":"client_reported","timing_output_tokens":output,"scope":"request","status":"completed"}})
}
fn ledger() -> Ledger {
    Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap()
}
#[test]
fn e4_v5_migration_backup_is_consistent_with_live_wal_and_repeat_open() {
    let temp = tempfile::tempdir().unwrap();
    let file = temp.path().join("ledger.db");
    let old = Connection::open(&file).unwrap();
    old.execute_batch(include_str!("ledger/schema.sql"))
        .unwrap();
    old.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=5; INSERT INTO usage_records(record_key,content_hash,source,kind,observed_at) VALUES ('old','hash','kimi','event','2026-01-15')").unwrap();
    let new = Ledger::open(&file, Clock::Fixed(1768478400000)).unwrap();
    let columns = rows(&new.db, "PRAGMA table_info(usage_timings)", &[]).unwrap();
    for name in ["duration_ms", "duration_method"] {
        assert!(columns.iter().any(|r| r["name"] == name));
    }
    assert_eq!(
        new.db
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        7
    );
    let backups = std::fs::read_dir(temp.path())
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .contains("v5-2026-01-15")
        })
        .collect::<Vec<_>>();
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert!(rows(
        &backup,
        "SELECT name FROM sqlite_master WHERE name='usage_timings'",
        &[]
    )
    .unwrap()
    .is_empty());
    assert_eq!(
        rows(
            &backup,
            "SELECT record_key,content_hash FROM usage_records",
            &[]
        )
        .unwrap(),
        rows(
            &new.db,
            "SELECT record_key,content_hash FROM usage_records",
            &[]
        )
        .unwrap()
    );
    assert_eq!(
        backup
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        5
    );
    assert_eq!(
        backup
            .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    drop(Ledger::open(&file, Clock::System).unwrap());
    assert_eq!(
        std::fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains("v5-"))
            .count(),
        1
    );
}
#[test]
fn e4_timing_only_update_preserves_usage_and_reprice_and_clears_with_timing_upgrade() {
    let db = ledger();
    let mut r = record("a", 100, 20, 500);
    r["timing"]["status"] = json!("partial");
    db.batch_with_timing_revision(
        &[r.clone()],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    let before = rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap();
    let hash = rows(&db.db, "SELECT timing_hash FROM usage_timings", &[]).unwrap();
    r["timing"]["ttft_ms"] = json!(300);
    for _ in 0..2 {
        db.batch_with_timing_revision(
            &[r.clone()],
            Some("log"),
            Some(5),
            Some(1),
            &[],
            pricing::cost_of,
        )
        .unwrap();
    }
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_records", &[]).unwrap(),
        before
    );
    assert_ne!(
        rows(&db.db, "SELECT timing_hash FROM usage_timings", &[]).unwrap(),
        hash
    );
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_timings", &[])
            .unwrap()
            .len(),
        1
    );
    r.as_object_mut().unwrap().remove("timing");
    db.batch_with_timing_revision(&[r], Some("log"), Some(5), Some(2), &[], pricing::cost_of)
        .unwrap();
    assert!(rows(&db.db, "SELECT * FROM usage_timings", &[])
        .unwrap()
        .is_empty());
}
#[test]
fn e4_nearest_rank_weighted_speed_coverage_status_and_active_filters() {
    let db = ledger();
    let mut items = (1..=10)
        .map(|i| {
            record(
                &i.to_string(),
                i * 100,
                i * 10,
                if i == 10 { 10000 } else { 1000 },
            )
        })
        .collect::<Vec<_>>();
    let mut partial = record("partial", 2000, 9999, 1);
    partial["timing"]["status"] = json!("partial");
    items.push(partial);
    let mut missing = record("missing", 999, 10, 500);
    missing.as_object_mut().unwrap().remove("timing");
    items.push(missing);
    let mut cumulative = record("cumulative", 1, 999, 1);
    cumulative["kind"] = json!("cumulative");
    items.push(cumulative);
    let mut other = record("other", 9999, 9999, 1);
    other["model"] = json!("else");
    items.push(other);
    db.batch(&items, Some("log"), Some(6), &[], pricing::cost_of)
        .unwrap();
    db.db
        .execute(
            "UPDATE usage_records SET active=0 WHERE record_key='other'",
            [],
        )
        .unwrap();
    let result=service::breakdown(&db,&json!({"by":"model","source":"kimi","model":"m","project":"p","from":"2026-01-15","to":"2026-01-15"}),0,"UTC").unwrap();
    let timing = &result["groups"][0]["timing"];
    assert_eq!(timing["request_count"], 12);
    assert_eq!(timing["ttft"][0]["sample_count"], 11);
    assert_eq!(timing["ttft"][0]["median_ms"], 600);
    assert_eq!(timing["ttft"][0]["p90_ms"], 1000);
    assert_eq!(timing["speed"][0]["sample_count"], 10);
    assert_eq!(timing["speed"][0]["output_tokens"], 550);
    assert_eq!(timing["speed"][0]["generation_ms"], 19000);
    assert!(
        (timing["speed"][0]["tokens_per_second"].as_f64().unwrap() - 550000.0 / 19000.0).abs()
            < 1e-9
    );
    let detail = service::session_detail(
        &db,
        &json!({"source":"kimi","session_id":"s","granularity":"day","model":"m"}),
        0,
        "UTC",
    )
    .unwrap()
    .unwrap();
    assert_eq!(detail["timing"], *timing);
}

#[test]
fn e4_kimi_ambiguous_usage_does_not_invent_timing() {
    let u = json!({"type":"usage.record","time":1768435201000_i64,"usage":{"inputOther":10,"output":20}});
    let r = parse(
        "kimi",
        &[
            u.clone(),
            u,
            json!({"type":"context.append_loop_event","event":{"type":"step.end","usage":{"inputOther":10,"output":20},"finishReason":"tool_use","llmFirstTokenLatencyMs":100,"llmStreamDurationMs":500}}),
        ],
    );
    assert_eq!(r.len(), 2);
    for row in r {
        assert!(row["timing"]["ttft_ms"].is_null());
        assert_eq!(row["timing"]["status"], "unknown");
    }
}
#[test]
fn e4_empty_new_timing_revokes_timings_but_same_revision_pruning_keeps_them() {
    let db = ledger();
    db.batch_with_timing_revision(
        &[record("old", 100, 20, 500)],
        Some("log"),
        Some(5),
        Some(1),
        &[],
        pricing::cost_of,
    )
    .unwrap();
    db.batch_with_timing_revision(&[], Some("log"), Some(5), Some(1), &[], pricing::cost_of)
        .unwrap();
    assert_eq!(
        rows(&db.db, "SELECT * FROM usage_timings", &[])
            .unwrap()
            .len(),
        1
    );
    db.batch_with_timing_revision(&[], Some("log"), Some(5), Some(2), &[], pricing::cost_of)
        .unwrap();
    assert!(rows(&db.db, "SELECT * FROM usage_timings", &[])
        .unwrap()
        .is_empty());
    assert_eq!(
        rows(&db.db, "SELECT active FROM usage_records", &[]).unwrap()[0]["active"],
        1
    );
}
#[test]
fn e4_methods_never_mix_and_group_sums_still_equal_totals() {
    let db = ledger();
    let mut a = record("a", 100, 20, 500);
    a["model"] = json!("claude-opus-5-5");
    let mut r = record("b", 1000, 100, 500);
    r["model"] = a["model"].clone();
    r["source"] = json!("codex");
    r["timing"]["ttft_method"] = json!("log_timestamps");
    r["timing"]["generation_method"] = json!("log_timestamps");
    db.batch(&[a, r], Some("log"), Some(6), &[], pricing::cost_of)
        .unwrap();
    let all = service::breakdown(&db, &json!({"by":"model"}), 0, "UTC").unwrap();
    assert!(
        db.totals(&json!({})).unwrap()["cost_micros"]
            .as_i64()
            .unwrap()
            > 0
    );
    assert_eq!(
        all["groups"][0]["timing"]["ttft"].as_array().unwrap().len(),
        2
    );
    assert_eq!(
        all["groups"][0]["timing"]["speed"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let detail = service::breakdown(&db, &json!({"by":"source_model"}), 0, "UTC").unwrap();
    for group in detail["groups"].as_array().unwrap() {
        assert_eq!(group["model_timing"], all["groups"][0]["timing"]);
    }
    for by in ["source", "model", "project", "source_model"] {
        let result = service::breakdown(&db, &json!({"by":by}), 0, "UTC").unwrap();
        let raw = if by == "source_model" {
            db.grouped("source", "model", &json!({})).unwrap()
        } else {
            db.breakdown(by, &json!({})).unwrap()
        };
        assert_eq!(
            raw.iter()
                .map(|g| g["cost_micros"].as_i64().unwrap())
                .sum::<i64>(),
            db.totals(&json!({})).unwrap()["cost_micros"]
                .as_i64()
                .unwrap()
        );
        for field in [
            "gross_tokens",
            "input_tokens",
            "output_tokens",
            "cost_micros",
            "request_count",
        ] {
            let sum = result["groups"]
                .as_array()
                .unwrap()
                .iter()
                .map(|g| g[field].as_i64().unwrap_or(0))
                .sum::<i64>();
            if field == "request_count" {
                assert_eq!(sum, 2);
            } else {
                assert_eq!(sum, result["totals"][field].as_i64().unwrap_or(0));
            }
        }
    }
    let empty =
        service::breakdown(&db, &json!({"by":"model","source":"absent"}), 0, "UTC").unwrap();
    assert!(empty["groups"].as_array().unwrap().is_empty());
    assert!(db.timing_summary(&json!({"source":"absent"})).unwrap()["speed"].is_null());
}

#[test]
fn e4_even_nearest_rank_and_noncompleted_speed_exclusion() {
    let db = ledger();
    let records = (1..=4)
        .map(|i| record(&i.to_string(), i * 100, 10, 100))
        .collect::<Vec<_>>();
    db.batch(&records, None, None, &[], pricing::cost_of)
        .unwrap();
    let t = db.timing_summary(&json!({})).unwrap();
    assert_eq!(t["ttft"][0]["median_ms"], 200);
    assert_eq!(t["ttft"][0]["p90_ms"], 400);
    for status in ["partial", "failed", "cancelled", "unknown"] {
        let mut r = record("incomplete", 0, 10, 100);
        r["source"] = json!("other");
        r["timing"]["status"] = json!(status);
        db.batch(&[r], None, None, &[], pricing::cost_of).unwrap();
        let t = db.timing_summary(&json!({"source":"other"})).unwrap();
        assert!(t["speed"].is_null());
        assert_eq!(t["ttft"][0]["median_ms"], 0);
        assert_eq!(t["request_count"], 1);
    }
}
#[test]
fn e4_codex_cross_file_timing_follows_usage_owner_and_repeat_is_idempotent() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let logs = home.join(".codex/sessions");
    std::fs::create_dir_all(&logs).unwrap();
    for (name, start) in [("rollout-a.jsonl", MS), ("rollout-b.jsonl", MS + 500)] {
        let values = [
            boundary("task_started", START),
            first("Reasoning", json!(start)),
            usage(END, "resp_abcdef0123456789"),
        ];
        std::fs::write(
            logs.join(name),
            values
                .iter()
                .map(|v| v.to_string() + "\n")
                .collect::<String>(),
        )
        .unwrap();
    }
    let env = super::ingest::Environment {
        platform: "win32".into(),
        vars: ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"]
            .map(|key| (key.into(), home.join(key).to_string_lossy().into_owned()))
            .into(),
        ..Default::default()
    };
    for pass in 0..2 {
        let result = super::ingest::sync(
            &root.path().join("data"),
            &home,
            &env,
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(0),
            &std::sync::atomic::AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(
            result["counts"]["cross_file_copies"],
            if pass == 0 { 1 } else { 0 }
        );
        assert_eq!(result["skippedFiles"], if pass == 0 { 0 } else { 2 });
        assert_eq!(result["inserted"], if pass == 0 { 1 } else { 0 });
        assert_eq!(result["updated"], 0);
    }
    let db = Ledger::open(&root.path().join("data/ledger.db"), Clock::System).unwrap();
    let row=rows(&db.db,"SELECT u.source_file AS usage_file,t.* FROM usage_records u JOIN usage_timings t USING(record_key)",&[]).unwrap();
    assert_eq!(row.len(), 1);
    assert_eq!(row[0]["source_file"], row[0]["usage_file"]);
    assert!(row[0]["source_file"]
        .as_str()
        .unwrap()
        .ends_with("rollout-a.jsonl"));
    assert_eq!(row[0]["ttft_ms"], 2000);
}

#[tokio::test]
#[ignore = "Requires explicitly authorized read-only Kimi log root and numeric audit file"]
async fn e4_kimi_real_log_ffi_matches_independent_audit() {
    let input = std::env::var("TOKEN_LENS_E4_KIMI_LOG_ROOT").unwrap();
    let expected: Value = serde_json::from_str(
        &std::fs::read_to_string(std::env::var("TOKEN_LENS_E4_TIMING_AUDIT").unwrap()).unwrap(),
    )
    .unwrap();
    let mut pending = vec![std::path::PathBuf::from(input)];
    let mut files = Vec::new();
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            let ty = entry.file_type().unwrap();
            if ty.is_symlink() {
                continue;
            }
            if ty.is_dir() {
                pending.push(entry.path());
            } else if entry.file_name() == "wire.jsonl" {
                files.push(entry.path());
            }
        }
    }
    assert_eq!(
        files.len() as u64,
        expected["kimi"]["files"].as_u64().unwrap()
    );
    let temp = tempfile::tempdir().unwrap();
    let db = Ledger::open(
        &temp.path().join("data/ledger.db"),
        Clock::Fixed(1768478400000),
    )
    .unwrap();
    for file in files {
        let identity = file.to_str().unwrap();
        let (records, notes) =
            adapters::parse("kimi", identity, &file, &LocalZone::Fixed(0)).unwrap();
        assert_eq!(notes["bad_lines"], 0);
        assert_eq!(notes["bad_fields"], 0);
        db.batch(
            &records,
            Some(identity),
            Some(adapters::parser_rev("kimi")),
            &[],
            pricing::cost_of,
        )
        .unwrap();
    }
    let client = crate::api::stats::StatsClient::new_with_fixed_clock(
        temp.path().join("data").to_string_lossy().into_owned(),
        Some(
            temp.path()
                .join("synthetic-home")
                .to_string_lossy()
                .into_owned(),
        ),
        1768478400000,
    )
    .unwrap();
    let groups = client
        .breakdown("source".into(), Default::default(), 0)
        .unwrap();
    let result = groups.groups[0].timing.as_ref().unwrap();
    let ttft = &result.ttft.as_ref().unwrap()[0];
    let speed = &result.speed.as_ref().unwrap()[0];
    let want = &expected["kimi"];
    assert_eq!(result.request_count, want["N"]);
    assert_eq!(ttft.sample_count, want["ttft_n"]);
    assert_eq!(ttft.median_ms, want["median_ms"]);
    assert_eq!(ttft.p90_ms, want["p90_ms"]);
    assert_eq!(speed.sample_count, want["speed_n"]);
    assert_eq!(speed.output_tokens, want["output_tokens"]);
    assert_eq!(speed.generation_ms, want["generation_ms"]);
    assert!((speed.tokens_per_second - want["tokens_per_second"].as_f64().unwrap()).abs() < 1e-10);
    client.shutdown().await;
}
