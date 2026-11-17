use super::*;
use crate::stats::{clock::Clock, pricing};
use std::path::Path;

fn ledger() -> Ledger {
    let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
    for i in 0..12 {
        let record = json!({"record_key":format!("r{i:02}"),"source":"codex","session_id":if i<10 {"a"} else {"b"},"project_key":"project","model":"unknown","observed_at":"2026-01-14T23:30:00.000Z","input_tokens":i,"output_tokens":10,"cache_read_tokens":null,"cache_write_tokens":2});
        ledger
            .batch(&[record], None, None, &[], pricing::cost_of)
            .unwrap();
        ledger.db.execute("UPDATE usage_records SET cost_micros=CASE WHEN input_tokens%3=0 THEN NULL ELSE input_tokens END", []).unwrap();
        if i < 11 {
            ledger.db.execute("INSERT INTO usage_timings(record_key,source,ttft_ms,generation_ms,duration_ms,timing_output_tokens,scope,status,timing_hash) VALUES (?1,'codex',?2,1000,2000,?3,'request','completed','synthetic')", rusqlite::params![format!("r{i:02}"),i*100,i+1]).unwrap();
        }
    }
    ledger.batch(&[
        json!({"record_key":"cumulative","source":"codex","session_id":"a","kind":"cumulative","observed_at":"2026-01-14T23:30:00.000Z","input_tokens":999}),
        json!({"record_key":"inactive","source":"codex","session_id":"a","observed_at":"2026-01-14T23:30:00.000Z","input_tokens":999}),
        json!({"record_key":"other-source","source":"claude","session_id":"a","observed_at":"2026-01-14T23:30:00.000Z","input_tokens":999}),
    ],None,None,&[],pricing::cost_of).unwrap();
    ledger
        .db
        .execute(
            "UPDATE usage_records SET active=0 WHERE record_key='inactive'",
            [],
        )
        .unwrap();
    ledger
}

#[test]
fn requests_reconcile_event_totals_and_preserve_null() {
    let ledger = ledger();
    let filter = json!({"from":"2026-01-15","to":"2026-01-15","offsetMinutes":480,"source":"codex","model":"unknown","project":"project"});
    let result = ledger
        .requests(&filter, false, "time", true, 100, 0)
        .unwrap();
    let total = ledger.totals(&filter).unwrap();
    let event_total = ledger.breakdown("source", &filter).unwrap().remove(0);
    assert_eq!(result["total"], event_total["request_count"]);
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 12);
    let mut gross = 0;
    for field in [
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    ] {
        let sum: i64 = items.iter().filter_map(|r| r[field].as_i64()).sum();
        assert_eq!(sum, total[field].as_i64().unwrap_or(0));
        gross += sum;
    }
    assert_eq!(gross, event_total["event_gross_tokens"]);
    assert!(items.iter().all(|r| r["cache_read_tokens"].is_null()));
    assert_eq!(items[0]["id"], "r00");
    assert_eq!(ledger.requests(&json!({"source":"codex","from":"2026-01-14","to":"2026-01-14","offsetMinutes":480}),false,"time",true,30,0).unwrap()["total"],0);
}

#[test]
fn requests_nulls_last_and_stable_sql_paging() {
    let ledger = ledger();
    for sort in ["time", "cost", "ttft", "speed"] {
        for descending in [false, true] {
            let all = ledger
                .requests(&json!({"source":"codex"}), false, sort, descending, 100, 0)
                .unwrap();
            let items = all["items"].as_array().unwrap();
            let mut pages = Vec::new();
            for offset in (0..12).step_by(3) {
                pages.extend(
                    ledger
                        .requests(
                            &json!({"source":"codex"}),
                            false,
                            sort,
                            descending,
                            3,
                            offset,
                        )
                        .unwrap()["items"]
                        .as_array()
                        .unwrap()
                        .clone(),
                );
            }
            assert_eq!(&pages, items);
            let field = match sort {
                "time" => "observed_at",
                "cost" => "cost_micros",
                "ttft" => "ttft_ms",
                _ => "speed_tps",
            };
            let mut missing = false;
            for r in items {
                if r[field].is_null() {
                    missing = true;
                } else {
                    assert!(!missing, "{sort}: non-null after null");
                }
            }
            if sort != "time" {
                assert!(missing);
            }
        }
    }
}

#[test]
fn requests_thresholds_use_full_scope_and_ignore_timed_filter() {
    let ledger = ledger();
    let filter = json!({"source":"codex"});
    let first = ledger.requests(&filter, false, "time", true, 1, 0).unwrap();
    assert_eq!(first["slow"], json!({"ttft_ms":900,"speed_tps":2.0}));
    assert_eq!(
        first["slow"],
        ledger.requests(&filter, true, "time", true, 1, 0).unwrap()["slow"]
    );
    ledger
        .db
        .execute(
            "UPDATE usage_timings SET scope='turn' WHERE record_key='r10'",
            [],
        )
        .unwrap();
    ledger
        .db
        .execute(
            "UPDATE usage_timings SET generation_ms=NULL WHERE record_key='r09'",
            [],
        )
        .unwrap();
    let result = ledger
        .requests(&filter, false, "speed", false, 100, 0)
        .unwrap();
    assert_eq!(result["slow"], json!({"ttft_ms":800,"speed_tps":null}));
    let avg = result["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "r09")
        .unwrap();
    assert_eq!(avg["speed_tps"], Value::Null);
    assert_eq!(avg["throughput_tps"], 5.0);
    ledger
        .db
        .execute(
            "UPDATE usage_timings SET status='failed' WHERE record_key='r08'",
            [],
        )
        .unwrap();
    let result = ledger
        .requests(&filter, false, "time", true, 100, 0)
        .unwrap();
    let failed = result["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "r08")
        .unwrap();
    assert_eq!(failed["ttft_ms"], 800);
    assert_eq!(failed["speed_tps"], Value::Null);
    assert_eq!(failed["throughput_tps"], Value::Null);
    assert_eq!(
        ledger
            .requests(
                &json!({"source":"codex","session":"b"}),
                false,
                "time",
                true,
                30,
                0
            )
            .unwrap()["slow"],
        json!({"ttft_ms":null,"speed_tps":null})
    );
    assert_eq!(
        ledger
            .requests(&filter, true, "time", true, 100, 0)
            .unwrap()["total"],
        11
    );
}

#[test]
fn requests_later_page_omits_summary() {
    let ledger = ledger();
    let page = ledger
        .requests(
            &json!({"source":"codex","include_summary":false}),
            false,
            "speed",
            false,
            3,
            3,
        )
        .unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 3);
    assert_eq!(page["total"], Value::Null);
    assert_eq!(page["slow"], Value::Null);
}

#[test]
fn requests_sort_direction_ties_and_average_fallback() {
    let ledger = ledger();
    ledger.db.execute("UPDATE usage_records SET observed_at='2026-01-15T01:00:00.000Z',cost_micros=100 WHERE record_key='r03'",[]).unwrap();
    ledger.db.execute("UPDATE usage_records SET observed_at='2026-01-15T02:00:00.000Z',cost_micros=100 WHERE record_key='r04'",[]).unwrap();
    for (sort, descending, first) in [
        ("time", true, "r04"),
        ("time", false, "r00"),
        ("cost", true, "r04"),
        ("cost", false, "r01"),
        ("ttft", true, "r10"),
        ("ttft", false, "r00"),
        ("speed", true, "r10"),
        ("speed", false, "r00"),
    ] {
        let result = ledger
            .requests(&json!({"source":"codex"}), false, sort, descending, 100, 0)
            .unwrap();
        assert_eq!(result["items"][0]["id"], first, "{sort} {descending}");
        if sort == "cost" && descending {
            assert_eq!(result["items"][1]["id"], "r03");
        }
    }
    ledger
        .db
        .execute(
            "UPDATE usage_timings SET generation_ms=NULL WHERE record_key='r10'",
            [],
        )
        .unwrap();
    let result = ledger
        .requests(&json!({"source":"codex"}), false, "speed", false, 100, 0)
        .unwrap();
    let ids: Vec<_> = result["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap())
        .collect();
    assert!(
        ids.iter().position(|id| *id == "r04").unwrap()
            < ids.iter().position(|id| *id == "r10").unwrap()
    );
    assert!(
        ids.iter().position(|id| *id == "r10").unwrap()
            < ids.iter().position(|id| *id == "r05").unwrap()
    );
    assert!(ledger
        .requests(&json!({}), false, "invalid", true, 30, 0)
        .is_err());
    assert!(ledger
        .requests(&json!({}), false, "time", true, 0, 0)
        .is_err());
    assert!(ledger
        .requests(&json!({}), false, "time", true, 30, -1)
        .is_err());
}

#[test]
fn requests_zero_or_unknown_timing_does_not_invent_speed() {
    let ledger = ledger();
    for status in ["partial", "failed", "cancelled", "unknown"] {
        ledger
            .db
            .execute(
                "UPDATE usage_timings SET status=?1 WHERE record_key='r00'",
                [status],
            )
            .unwrap();
        let result = ledger
            .requests(
                &json!({"session":"a","source":"codex"}),
                false,
                "time",
                true,
                30,
                0,
            )
            .unwrap();
        assert_eq!(result["items"][0]["ttft_ms"], 0);
        assert!(result["items"][0]["speed_tps"].is_null());
        assert!(result["items"][0]["throughput_tps"].is_null());
    }
    ledger.db.execute("UPDATE usage_timings SET status='completed',generation_ms=0,timing_output_tokens=NULL WHERE record_key='r00'",[]).unwrap();
    let result = ledger
        .requests(
            &json!({"session":"a","source":"codex"}),
            false,
            "time",
            true,
            30,
            0,
        )
        .unwrap();
    assert!(result["items"][0]["speed_tps"].is_null());
    assert!(result["items"][0]["throughput_tps"].is_null());
}

#[test]
fn requests_session_is_lifetime_and_source_scoped() {
    let ledger = ledger();
    let result=crate::stats::service::requests(&ledger,&json!({"from":"2025-01-01","to":"2025-01-02","source":"wrong","model":"wrong","project":"wrong","bucket":"2025-01-01T00:00:00","session_source":"codex","session_id":"a"}),480,"UTC").unwrap();
    assert_eq!(result["total"], 10);
    assert!(result["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["source"] == "codex" && r["session_id"] == "a"));
    assert_eq!(result["snapshot"]["filters"]["session_id"], "a");
    assert!(
        crate::stats::service::requests(&ledger, &json!({"session_source":"codex"}), 0, "UTC")
            .is_err()
    );
}

#[test]
fn requests_buckets_and_mixed_cumulative_reconcile_event_parts() {
    let ledger = ledger();
    for bucket in ["2026-01", "2026-01-15", "2026-01-15T07:00:00"] {
        let result = ledger
            .requests(
                &json!({"source":"codex","offsetMinutes":480,"bucket":bucket}),
                false,
                "time",
                true,
                100,
                0,
            )
            .unwrap();
        assert_eq!(result["total"], 12);
    }
    assert_eq!(
        ledger
            .requests(
                &json!({"offsetMinutes":480,"bucket":"2026-01-15T08:00:00"}),
                false,
                "time",
                true,
                30,
                0
            )
            .unwrap()["total"],
        0
    );
    let filter = json!({"source":"codex"});
    let all = ledger
        .requests(&filter, false, "time", true, 100, 0)
        .unwrap();
    let mixed = ledger.breakdown("source", &filter).unwrap().remove(0);
    let mut sum = 0;
    for field in [
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    ] {
        let event_sum: i64 = all["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|r| r[field].as_i64())
            .sum();
        let sql=format!("SELECT sum({field}) FROM usage_records WHERE +active=1 AND source='codex' AND kind='event'");
        let expected: Option<i64> = ledger.db.query_row(&sql, [], |r| r.get(0)).unwrap();
        assert_eq!(event_sum, expected.unwrap_or(0));
        sum += event_sum;
    }
    assert_eq!(all["total"], mixed["request_count"]);
    assert_eq!(sum, mixed["event_gross_tokens"]);
    assert_eq!(mixed["gross_tokens"].as_i64().unwrap(), sum + 999);
}

#[test]
#[ignore = "200k synthetic request query, run in release"]
fn requests_performance_200k() {
    let temp = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(&temp.path().join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
    ledger.db.execute_batch("BEGIN;
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<200000)
        INSERT INTO usage_records(record_key,content_hash,source,session_id,model,observed_at,kind,input_tokens,output_tokens,cost_micros)
        SELECT printf('r%06d',i),'synthetic','codex',printf('s%d',i/20),'synthetic-model','2026-01-15T00:00:00.000Z','event',i%1000,100,i%100 FROM n;
        INSERT INTO usage_timings(record_key,source,ttft_ms,generation_ms,duration_ms,timing_output_tokens,scope,status,timing_hash)
        SELECT record_key,source,id%5000,1000+id%9000,2000+id%9000,output_tokens,'request','completed','synthetic' FROM usage_records WHERE id%2=0;
        COMMIT;").unwrap();
    for (label,sql) in [
        ("page","EXPLAIN QUERY PLAN SELECT u.record_key FROM usage_records u LEFT JOIN usage_timings t ON t.record_key=u.record_key WHERE +u.active=1 AND u.kind='event' ORDER BY coalesce(CASE WHEN t.status='completed' AND t.generation_ms>0 THEN t.timing_output_tokens*1000.0/t.generation_ms END,CASE WHEN t.status='completed' AND t.duration_ms>0 THEN t.timing_output_tokens*1000.0/t.duration_ms END) ASC,u.observed_at DESC,u.record_key ASC LIMIT 30 OFFSET 300"),
        ("samples","EXPLAIN QUERY PLAN SELECT t.ttft_ms,t.generation_ms FROM usage_timings t JOIN usage_records u ON u.record_key=t.record_key WHERE +u.active=1 AND u.kind='event' AND t.scope='request'"),
    ] {
        println!("{label}_plan={}",json!(rows(&ledger.db,sql,&[]).unwrap()));
    }
    let mut times = Vec::new();
    for _ in 0..5 {
        let started = std::time::Instant::now();
        let result = ledger
            .requests(&json!({}), false, "speed", false, 30, 0)
            .unwrap();
        times.push(started.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(result["total"], 200000);
        assert_eq!(result["items"].as_array().unwrap().len(), 30);
        assert!(result["slow"]["ttft_ms"].is_number());
        assert!(result["slow"]["speed_tps"].is_number());
    }
    println!("requests_200k_first_page_runs_ms={times:?}");
    times.sort_by(f64::total_cmp);
    let started = std::time::Instant::now();
    let page = ledger
        .requests(
            &json!({"include_summary":false}),
            false,
            "speed",
            false,
            30,
            300,
        )
        .unwrap();
    let page_ms = started.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(page["items"].as_array().unwrap().len(), 30);
    assert!(page["total"].is_null());
    assert!(page["slow"].is_null());
    println!(
        "requests_200k_first_page_median_ms={:.3}; offset_300_ms={page_ms:.3}",
        times[2]
    );
    assert!(
        times[2] <= 500.0,
        "request query exceeded 500 ms: {}",
        times[2]
    );
}
