use super::*;
use crate::stats::clock::Clock;
use std::path::Path;

fn ledger() -> Ledger {
    let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
    let mut records = Vec::new();
    for (source, session, project, model, day, tokens, cost) in [
        (
            "claude",
            "alpha-id",
            "/one/Über",
            "alpha-model",
            15,
            30,
            Some(200),
        ),
        (
            "claude",
            "alpha-id",
            "/one/Über",
            "older-model",
            12,
            8,
            Some(5),
        ),
        (
            "codex",
            "beta-id",
            "/two/Other",
            "beta-model",
            16,
            20,
            Some(100),
        ),
        (
            "codex",
            "beta-id",
            "/two/Other",
            "beta-model",
            17,
            20,
            Some(100),
        ),
        (
            "gemini",
            "gamma-id",
            "/one/Über",
            "gamma-model",
            14,
            60,
            None,
        ),
        (
            "claude",
            "delta-id",
            "/one/Über",
            "delta-model",
            18,
            10,
            Some(0),
        ),
        (
            "codex",
            "delta-id",
            "/one/Über",
            "delta-model",
            18,
            10,
            Some(0),
        ),
    ] {
        records.push(json!({
            "record_key":format!("{source}-{session}-{day}"),
            "source":source,"session_id":session,"project_key":project,"model":model,
            "observed_at":format!("2026-01-{day:02}T12:00:00.000Z"),
            "input_tokens":tokens,"cost":cost,
        }));
    }
    ledger
        .batch(
            &records,
            None,
            None,
            &[],
            |row| json!({"cost_micros":row["cost"],"price_source":"synthetic"}),
        )
        .unwrap();
    ledger
}

fn ids(result: &Value) -> Vec<String> {
    result["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            format!(
                "{}/{}",
                row["session_id"].as_str().unwrap(),
                row["source"].as_str().unwrap()
            )
        })
        .collect()
}

#[test]
fn s5_session_search_checks_all_display_fields_before_pagination() {
    let ledger = ledger();
    for (query, expected) in [
        ("ALPHA-ID", vec!["alpha-id/claude"]),
        ("CODE CLI", vec![]),
        ("MINI CLI", vec!["gamma-id/gemini"]),
        ("BETA-MODEL", vec!["beta-id/codex"]),
        ("OLDER-MODEL", vec!["alpha-id/claude"]),
        (
            "ÜBER",
            vec!["alpha-id/claude", "delta-id/claude", "delta-id/codex"],
        ),
        (
            "/ONE/ÜB",
            vec!["alpha-id/claude", "delta-id/claude", "delta-id/codex"],
        ),
        ("NO-MODEL", vec![]),
        ("/OTHER-PROJECT", vec![]),
        ("ghost-id", vec![]),
        ("%", vec![]),
    ] {
        let mut params = json!({"q":query,"limit":1,"sort":"tokens","dir":"desc",
            "from":"2026-01-14","project":"/one/Über","exclude_sources":["gemini"]});
        if !query.contains('Ü') {
            params["project"] = Value::Null;
            params["exclude_sources"] = Value::Null;
        }
        let mut all = Vec::new();
        loop {
            let page = sessions(&ledger, &params, 0, "UTC").unwrap();
            all.extend(ids(&page));
            if page["next_cursor"].is_null() {
                break;
            }
            assert!(all.len() < 6, "cursor did not advance");
            params["cursor"] = page["next_cursor"].clone();
        }
        assert_eq!(all, expected, "{query}");
    }
    let constrained = json!({
        "q":"ÜBER","from":"2026-01-15","to":"2026-01-16",
        "source":"claude","project":"/one/Über","exclude_sources":["codex"]
    });
    assert_eq!(
        ids(&sessions(&ledger, &constrained, 0, "UTC").unwrap()),
        ["alpha-id/claude"]
    );
}

#[test]
fn s5_session_sort_and_stable_pagination() {
    let ledger = ledger();
    let a = "alpha-id/claude";
    let b = "beta-id/codex";
    let g = "gamma-id/gemini";
    let c = "delta-id/claude";
    let d = "delta-id/codex";
    for (sort, asc, desc) in [
        ("tokens", [c, d, a, b, g], [g, b, a, c, d]),
        ("cost", [c, d, a, b, g], [a, b, c, d, g]),
        ("started", [a, g, b, c, d], [c, d, b, g, a]),
        ("recent", [g, a, b, c, d], [c, d, b, a, g]),
        ("requests", [a, c, d, g, b], [b, a, c, d, g]),
    ] {
        for (dir, expected) in [("asc", asc), ("desc", desc)] {
            let mut params = json!({"sort":sort,"dir":dir,"from":"2026-01-14","limit":2});
            let mut got = Vec::new();
            for _ in 0..3 {
                let result = sessions(&ledger, &params, 0, "UTC").unwrap();
                got.extend(ids(&result));
                params["cursor"] = result["next_cursor"].clone();
            }
            assert!(params["cursor"].is_null());
            assert_eq!(got, expected, "{sort} {dir}");
        }
    }
    let old = sessions(&ledger, &json!({"from":"2026-01-14"}), 0, "UTC").unwrap();
    let default = sessions(&ledger, &json!({"from":"2026-01-14","q":""}), 0, "UTC").unwrap();
    assert_eq!(old, default);
}

#[test]
fn s5_comparison_reconciles_totals_and_keeps_both_periods_groups() {
    let ledger = ledger();
    let current = json!({"from":"2026-01-16","to":"2026-01-18","exclude_sources":["claude"]});
    let previous = json!({"from":"2026-01-12","to":"2026-01-15","exclude_sources":["claude"]});
    for by in ["project", "source", "model"] {
        let result = comparison(&ledger, by, &current, &previous, 0).unwrap();
        let mut by_key = std::collections::HashMap::<Option<String>, (i64, i64)>::new();
        for (side, params, sign) in [("current", &current, 1), ("previous", &previous, -1)] {
            let totals = ledger.totals(&filter(params, 0).unwrap()).unwrap();
            let groups = result[side]["groups"]
                .as_array()
                .expect("missing comparison groups");
            assert_eq!(
                result[side]["totals"]["gross_tokens"],
                totals["gross_tokens"]
            );
            assert_eq!(result[side]["totals"]["cost_micros"], totals["cost_micros"]);
            for key in ["gross_tokens", "cost_micros", "unpriced_records"] {
                assert_eq!(
                    groups
                        .iter()
                        .map(|row| row[key].as_i64().unwrap_or(0))
                        .sum::<i64>(),
                    totals[key].as_i64().unwrap_or(0),
                    "{by} {side} {key}",
                );
            }
            assert!(groups.iter().all(|row| row["key"] != "claude"));
            for row in groups {
                let entry = by_key
                    .entry(row["key"].as_str().map(str::to_owned))
                    .or_default();
                entry.0 += sign * row["gross_tokens"].as_i64().unwrap();
                entry.1 += sign * row["cost_micros"].as_i64().unwrap_or(0);
            }
        }
        assert_eq!(by_key.values().map(|r| r.0).sum::<i64>(), -10);
        assert_eq!(by_key.values().map(|r| r.1).sum::<i64>(), 200);
        let rows = |side: &str| result[side]["groups"].as_array().unwrap();
        assert!(rows("current")
            .iter()
            .any(|r| !rows("previous").iter().any(|p| p["key"] == r["key"])));
        if by != "project" {
            assert!(rows("previous")
                .iter()
                .any(|r| !rows("current").iter().any(|p| p["key"] == r["key"])));
        }
    }
}

#[test]
fn s5_comparison_reads_one_snapshot_across_a_concurrent_commit() {
    let folder = tempfile::tempdir().unwrap();
    let db = folder.path().join("synthetic.db");
    let reader = Ledger::open(&db, Clock::Fixed(1768478400000)).unwrap();
    let writer = Ledger::open(&db, Clock::Fixed(1768478400000)).unwrap();
    let current = json!({"from":"2026-01-16","to":"2026-01-16"});
    let previous = json!({"from":"2026-01-15","to":"2026-01-15"});
    let insert =
        |day: u8, n: i64| {
            writer.batch(&[json!({
            "record_key":format!("s{day}"),"source":"claude","session_id":"s","model":"m",
            "observed_at":format!("2026-01-{day:02}T12:00:00.000Z"),"input_tokens":n,
        })],None,None,&[],pricing::cost_of).unwrap();
        };
    insert(16, 100);
    let result = comparison_with(&reader, "source", &current, &previous, 0, || {
        insert(15, 200);
    })
    .unwrap();
    assert_eq!(result["current"]["totals"]["gross_tokens"], 100);
    assert_eq!(result["previous"]["totals"]["gross_tokens"], 0);
    let fresh = comparison(&reader, "source", &current, &previous, 0).unwrap();
    assert_eq!(fresh["previous"]["totals"]["gross_tokens"], 200);
}
