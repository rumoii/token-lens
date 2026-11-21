use super::*;
use crate::stats::{clock::Clock, ingest, jscompat, jscompat::LocalZone};
use std::{path::Path, sync::atomic::AtomicBool};

const NOW: &str = "2026-01-15T12:00:00.000Z";
const MILLIS: i64 = 1768478400000;
const RUST_ONLY_SOURCES: &[&str] = &["antigravity"];

fn sorted_list(value: &mut Value) {
    if let Some(array) = value.as_array_mut() {
        array.sort_by_key(|row| {
            json!([
                row["bucket"],
                row["group"],
                row["key"],
                row["source"],
                row["model"],
                row["project_key"],
                row["session_id"]
            ])
            .to_string()
        });
    }
}

fn ordered(name: &str, mut value: Value) -> Value {
    match name {
        "read.breakdown" => sorted_list(&mut value),
        // Price rows retain the Node values; their desktop order is token-based.
        // f1_prices_sort_by_displayed_tokens_then_model pins the new order.
        "read.model_price_marks" => sorted_list(&mut value),
        "pricing" => sorted_list(&mut value["models"]),
        "breakdown" => sorted_list(&mut value["groups"]),
        "read.matrix" | "matrix" => sorted_list(&mut value["rows"]),
        "read.session_detail" | "session_detail" if !value.is_null() => {
            sorted_list(&mut value["models"])
        }
        "read.sessions" | "sessions" => sorted_list(&mut value["items"]),
        _ => {}
    }
    value
}

fn conserved(totals: &Value, rows: &[Value]) {
    for key in [
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "cost_micros",
    ] {
        assert_eq!(
            rows.iter()
                .map(|row| row[key].as_i64().unwrap_or(0))
                .sum::<i64>(),
            totals[key].as_i64().unwrap_or(0),
            "{key}"
        );
    }
}

fn check_invariant(ledger: &Ledger, row: &Value, actual: &Value) {
    let name = row["fn"].as_str().unwrap();
    if name == "read.breakdown" {
        conserved(
            &ledger.totals(&row["filter"]).unwrap(),
            actual.as_array().unwrap(),
        );
    }
    if row["scenario"] == "A" && matches!(name, "read.timeseries" | "read.matrix") {
        let key = if name == "read.matrix" {
            "rows"
        } else {
            "points"
        };
        let mut values = actual[key].as_array().unwrap().clone();
        if !actual["unallocated"].is_null() {
            values.push(actual["unallocated"].clone());
        }
        conserved(&ledger.totals(&row["filter"]).unwrap(), &values);
    }
}

#[test]
fn d33_queries_match_node_golden_and_conserve() {
    let evidence: Value = serde_json::from_str(source_notes::EVIDENCE).unwrap();
    let rust_only_evidence = RUST_ONLY_SOURCES
        .iter()
        .filter(|source| evidence.get(**source).is_some())
        .count();
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/parity/queries");
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    std::fs::create_dir_all(&home).unwrap();
    let environment = ingest::Environment {
        platform: if cfg!(windows) {
            "win32"
        } else if cfg!(target_os = "macos") {
            "darwin"
        } else {
            "linux"
        }
        .into(),
        vars: ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"]
            .into_iter()
            .map(|key| {
                (
                    key.to_string(),
                    home.join(key).to_string_lossy().into_owned(),
                )
            })
            .collect(),
        ..Default::default()
    };
    let mut ledger: Option<Ledger> = None;
    let mut compared = 0;
    for (line_number, line) in include_str!("../../../tests/golden/queries-d33.jsonl")
        .lines()
        .enumerate()
    {
        let mut row: Value = serde_json::from_str(line).unwrap();
        crate::stats::update_golden_price_version(&mut row["expected"]);
        // Scenario B's fixtures and query goldens use Windows APPDATA/LOCALAPPDATA roots.
        #[cfg(not(windows))]
        if row["scenario"] == "B" {
            continue;
        }
        match row["type"].as_str().unwrap() {
            "context" => assert_eq!(row["now"], NOW),
            "setup" => {
                let records: Vec<Value> = serde_json::from_str(
                    &std::fs::read_to_string(fixtures.join(row["fixture"].as_str().unwrap()))
                        .unwrap(),
                )
                .unwrap();
                let value = Ledger::open(Path::new(":memory:"), Clock::Fixed(MILLIS)).unwrap();
                assert_eq!(
                    value
                        .batch(&records, None, None, &[], pricing::cost_of)
                        .unwrap(),
                    row["expected"]
                );
                ledger = Some(value);
            }
            "sql" => ledger
                .as_ref()
                .unwrap()
                .db
                .execute_batch(row["sql"].as_str().unwrap())
                .unwrap(),
            "setup_b" => {
                for entry in row["files"].as_array().unwrap() {
                    let target = home.join(entry["target"].as_str().unwrap());
                    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
                    let input = crate::stats::golden_fixture(entry["input"].as_str().unwrap());
                    if input.extension().is_some_and(|s| s == "sql") {
                        let db = rusqlite::Connection::open(&target).unwrap();
                        db.execute_batch(&std::fs::read_to_string(input).unwrap())
                            .unwrap();
                    } else {
                        std::fs::copy(input, target).unwrap();
                    }
                }
            }
            "run" => {
                let mut actual = ingest::reread(
                    &data,
                    &home,
                    &environment,
                    Clock::Fixed(MILLIS),
                    &LocalZone::Fixed(480),
                    &AtomicBool::new(false),
                )
                .unwrap();
                actual["durationMs"] = json!("<volatile>");
                assert_eq!(actual, row["expected"], "run {}", row["index"]);
                ledger = Some(Ledger::open(&data.join("ledger.db"), Clock::Fixed(MILLIS)).unwrap());
            }
            "query" => {
                let ledger = ledger.as_ref().unwrap();
                let name = row["fn"].as_str().unwrap();
                let params = &row["params"];
                let offset = row["offsetMinutes"].as_i64().unwrap_or(0) as i32;
                let tz = params["tz"].as_str().unwrap_or("Asia/Shanghai");
                let actual = match name {
                    "cursor.encode" => {
                        json!(jscompat::encode_cursor(row["value"].as_u64().unwrap()))
                    }
                    "cursor.decode" => json!(jscompat::decode_cursor(row["value"].as_str())),
                    "read.totals" => ledger.totals(&row["filter"]).unwrap(),
                    "read.breakdown" => json!(ledger
                        .breakdown(row["by"].as_str().unwrap(), &row["filter"])
                        .unwrap()),
                    "read.timeseries" => ledger
                        .timeseries(row["granularity"].as_str().unwrap(), &row["filter"])
                        .unwrap(),
                    "read.matrix" => ledger
                        .timeseries_grouped(
                            row["granularity"].as_str().unwrap(),
                            row["by"].as_str().unwrap(),
                            &row["filter"],
                        )
                        .unwrap(),
                    "summary" => summary(ledger, params, offset, tz).unwrap(),
                    "breakdown" => breakdown(ledger, params, offset, tz).unwrap(),
                    "timeseries" => timeseries(ledger, params, offset, tz).unwrap(),
                    "matrix" => matrix(ledger, params, offset, tz).unwrap(),
                    "sessions" => sessions(ledger, params, offset, tz).unwrap(),
                    "read.sessions" => {
                        let (items, next) = ledger
                            .sessions(
                                params["limit"].as_i64(),
                                jscompat::decode_cursor(params["cursor"].as_str()),
                                &json!({"offsetMinutes":offset}),
                            )
                            .unwrap();
                        json!({"items":items,"next_cursor":next.map(jscompat::encode_cursor)})
                    }
                    "read.session_detail" => ledger
                        .session_detail(
                            params["source"].as_str().unwrap(),
                            params["session_id"].as_str().unwrap(),
                            params["granularity"].as_str().unwrap(),
                            offset,
                        )
                        .unwrap()
                        .unwrap_or(Value::Null),
                    "session_detail" => session_detail(ledger, params, offset, tz)
                        .unwrap()
                        .unwrap_or(json!({"notFound":true})),
                    "read.legacy_count" => json!(ledger.legacy_count().unwrap()),
                    "read.source_status" => json!(ledger.source_status().unwrap()),
                    "read.source_checks" => ledger.source_checks(NOW).unwrap(),
                    "read.source_files" => json!(ledger.source_files().unwrap()),
                    "read.model_price_marks" => json!(ledger.model_price_marks().unwrap()),
                    "read.last_run" => ledger.last_run().unwrap(),
                    "sources" => sources(
                        ledger,
                        NOW,
                        |path| {
                            if row["scenario"] == "B" {
                                Path::new(path).exists()
                            } else {
                                path == "synthetic-kept"
                            }
                        },
                        tz,
                    )
                    .unwrap(),
                    "pricing" => pricing(ledger, tz).unwrap(),
                    "discovery" => discovery(&home, &environment),
                    _ => panic!("unknown golden query: {name}"),
                };
                let mut actual = actual;
                let mut expected = row["expected"].clone();
                // The frozen Node registry cannot include Rust-only sources.
                match name {
                    "sources" => {
                        for source in actual["sources"].as_array_mut().unwrap() {
                            let fields = source.as_object_mut().unwrap();
                            let limits_en = fields.remove("limits_en").unwrap();
                            assert_eq!(
                                limits_en.as_array().unwrap().len(),
                                fields["limits"].as_array().unwrap().len(),
                            );
                            for limit in limits_en.as_array().unwrap() {
                                assert!(limit.as_str().is_some_and(|text| !text.is_empty()));
                            }
                            for note in fields.get_mut("notes").unwrap().as_array_mut().unwrap() {
                                let text_en =
                                    note.as_object_mut().unwrap().remove("text_en").unwrap();
                                assert!(text_en.as_str().is_some_and(|text| !text.is_empty()));
                            }
                        }
                        let known = row["expected"]["snapshot"]["known_sources"]
                            .as_u64()
                            .unwrap();
                        expected["snapshot"]["known_sources"] =
                            json!(known + rust_only_evidence as u64);
                    }
                    "pricing" => {
                        for model in expected["models"].as_array_mut().unwrap() {
                            if model["model"] == "deepseek-flash" {
                                model["note"] = json!(model["note"]
                                    .as_str()
                                    .unwrap()
                                    .replace("登记 2026 年", "登记 2026 和 2027 年"));
                                model["time_of_day"]["holidays_count"] = json!(62);
                                model["time_of_day"]["holidays_through"] = json!("2027-10-07");
                            }
                        }
                        for model in actual["models"].as_array_mut().unwrap() {
                            let fields = model.as_object_mut().unwrap();
                            let note_en = fields.remove("note_en").unwrap();
                            if fields["note"].as_str().is_some_and(|note| !note.is_empty()) {
                                assert!(note_en.as_str().is_some_and(|note| !note.is_empty()));
                            }
                        }
                    }
                    "discovery" => {
                        let supported = row["expected"]["supported"].as_u64().unwrap();
                        expected["supported"] = json!(supported + RUST_ONLY_SOURCES.len() as u64);
                    }
                    _ => {}
                }
                crate::stats::timing_tests::strip_golden_timing(&mut actual);
                check_invariant(ledger, &row, &actual);
                assert_eq!(
                    ordered(name, actual),
                    ordered(name, expected),
                    "line {}: {name}",
                    line_number + 1
                );
                compared += 1;
            }
            kind => panic!("unknown golden row {kind}"),
        }
    }
    let expected_queries = 5743; // Scenarios A and invalid.
    #[cfg(windows)]
    let expected_queries = expected_queries + 4; // Scenario B.
    assert_eq!(compared, expected_queries);
}
