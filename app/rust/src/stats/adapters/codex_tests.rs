use crate::stats::{
    adapters,
    clock::Clock,
    ingest,
    jscompat::LocalZone,
    ledger::{self, Ledger},
    pricing, service,
};
use serde_json::{json, Value};
use std::{fs, path::Path, sync::atomic::AtomicBool};

const SESSION: &str = "00000000-0000-4000-8000-000000000001";
const ROOT: &str = "00000000-0000-4000-8000-000000000002";
const CHILD: &str = "00000000-0000-4000-8000-000000000003";
const TIME: &str = "2026-01-14T10:00:00Z";
const LONG_ID: &str = "resp_abcdef0123456789abcdef0123456789abcdef0123456789";

fn usage(thread: &str, time: &str, response: &str, input: i64) -> Value {
    json!({"type":"token_usage_record","timestamp":time,"payload":{
        "session_id":SESSION,"thread_id":thread,"turn_id":"invented-turn",
        "response_id":response,"usage":{"input_tokens":input,
        "cached_input_tokens":input / 2,"output_tokens":input / 10}}})
}

fn content(thread: &str, rows: &[Value]) -> String {
    let meta = json!({"type":"session_meta","payload":{"id":thread,
        "session_id":SESSION,"model":"gpt-synthetic",
        "source":if thread == CHILD {
            json!({"subagent":{"thread_spawn":{"parent_thread_id":ROOT,"depth":1}}})
        } else { json!("cli") }}});
    std::iter::once(meta)
        .chain(rows.iter().cloned())
        .map(|v| v.to_string() + "\n")
        .collect()
}

fn write(home: &Path, name: &str, thread: &str, rows: &[Value]) -> std::path::PathBuf {
    let file = home.join(".codex").join("sessions").join(name);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, content(thread, rows)).unwrap();
    file
}

fn parse(file: &Path) -> Vec<Value> {
    let (records, notes) =
        adapters::parse("codex", file.to_str().unwrap(), file, &LocalZone::Fixed(0)).unwrap();
    assert_eq!(
        notes,
        json!({"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0})
    );
    records
}

fn sync(root: &Path) -> Value {
    let home = root.join("home");
    let environment = ingest::Environment {
        platform: "win32".into(),
        vars: ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"]
            .map(|key| (key.into(), home.join(key).to_string_lossy().into_owned()))
            .into(),
    };
    let result = ingest::sync(
        &root.join("data"),
        &home,
        &environment,
        Clock::Fixed(1768478400000),
        &LocalZone::Fixed(0),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(result["counts"]["read_failed"], 0);
    result
}

fn ledger(root: &Path) -> Ledger {
    Ledger::open(&root.join("data/ledger.db"), Clock::Fixed(1768478400000)).unwrap()
}

fn keys(records: &[Value]) -> Vec<String> {
    records
        .iter()
        .map(|r| r["record_key"].as_str().unwrap().into())
        .collect()
}

fn minimal(home: &Path) -> std::path::PathBuf {
    let owner = write(
        home,
        "rollout-a.jsonl",
        ROOT,
        &[
            usage(ROOT, TIME, "resp_0", 100),
            usage(ROOT, "2026-01-14T10:01:00Z", "resp_0", 200),
        ],
    );
    write(
        home,
        "rollout-b.jsonl",
        CHILD,
        &[usage(CHILD, "2026-01-14T10:02:00Z", "resp_0", 300)],
    );
    owner
}

#[test]
fn e1_independent_root_and_subagent_requests_total_660_without_conflict() {
    let dir = tempfile::tempdir().unwrap();
    minimal(&dir.path().join("home"));
    let result = sync(dir.path());
    let ledger = ledger(dir.path());
    let totals = ledger.totals(&json!({})).unwrap();
    assert_eq!(
        totals["gross_tokens"], 660,
        "three independent requests must survive"
    );
    assert_eq!(totals["record_count"], 3);
    assert_eq!(result["counts"]["cross_file_copies"], 0);
    assert_eq!(result["anomalies"], json!([]));
    let summary = service::summary(&ledger, &json!({}), 0, "UTC").unwrap();
    assert_eq!(summary["totals"]["gross_tokens"], 660);
}

#[test]
fn e1_same_thread_turn_and_timestamp_get_stable_occurrence_suffixes() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let mut rows = vec![
        usage(ROOT, TIME, "resp_0", 100),
        usage(ROOT, TIME, "resp_0", 200),
    ];
    let file = write(&home, "rollout-a.jsonl", ROOT, &rows);
    let base = format!("codex|{SESSION}|{ROOT}|{TIME}");
    assert_eq!(keys(&parse(&file)), [base.clone(), format!("{base}#2")]);
    assert_eq!(sync(dir.path())["inserted"], 2);
    let repeated = sync(dir.path());
    assert_eq!(repeated["inserted"], 0);
    assert_eq!(repeated["unchanged"], 2);
    rows.push(usage(ROOT, TIME, "resp_0", 300));
    write(&home, "rollout-a.jsonl", ROOT, &rows);
    let appended = sync(dir.path());
    assert_eq!(appended["inserted"], 1);
    assert_eq!(appended["unchanged"], 2);
    assert_eq!(
        keys(&parse(&file)),
        [base.clone(), format!("{base}#2"), format!("{base}#3")]
    );
    assert_eq!(
        ledger(dir.path()).totals(&json!({})).unwrap()["gross_tokens"],
        660
    );
    rows[0]["payload"]["usage"]["input_tokens"] = json!(500);
    write(&home, "rollout-a.jsonl", ROOT, &rows);
    assert_eq!(keys(&parse(&file))[0], base, "tokens never enter identity");
}

#[test]
fn e1_copied_history_preserves_original_thread_identity_and_counts_once() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let history = vec![
        usage(ROOT, TIME, "resp_0", 100),
        usage(ROOT, TIME, "resp_0", 200),
    ];
    let original = write(&home, "rollout-a.jsonl", ROOT, &history);
    let copy = write(&home, "rollout-b.jsonl", CHILD, &history);
    assert_eq!(keys(&parse(&original)), keys(&parse(&copy)));
    let result = sync(dir.path());
    assert_eq!(result["counts"]["cross_file_copies"], 2);
    assert_eq!(result["anomalies"], json!([]));
    let totals = ledger(dir.path()).totals(&json!({})).unwrap();
    assert_eq!(totals["record_count"], 2);
    assert_eq!(totals["gross_tokens"], 330);
    let mut extended = history;
    extended.push(usage(CHILD, "2026-01-14T10:02:00Z", "resp_0", 300));
    write(&home, "rollout-b.jsonl", CHILD, &extended);
    let result = sync(dir.path());
    assert_eq!(result["inserted"], 1);
    assert_eq!(result["anomalies"], json!([]));
    assert_eq!(
        ledger(dir.path()).totals(&json!({})).unwrap()["gross_tokens"],
        660
    );
}

#[test]
fn e1_long_reliable_id_keeps_v4_key_bytes_and_identical_duplicates() {
    let dir = tempfile::tempdir().unwrap();
    let row = usage(ROOT, TIME, LONG_ID, 100);
    let file = write(dir.path(), "rollout-a.jsonl", ROOT, &[row.clone(), row]);
    let expected_v4 = format!("codex|{SESSION}|{LONG_ID}");
    let records = parse(&file);
    for record in records {
        assert_eq!(
            record["record_key"].as_str().unwrap().as_bytes(),
            expected_v4.as_bytes()
        );
        assert!(record.get("replaces").is_none());
    }
}

#[test]
fn e1_id_shape_boundary_and_missing_thread_use_position() {
    let dir = tempfile::tempdir().unwrap();
    for id in [
        "resp_",
        "resp_0",
        "resp_12345678901234567890",
        "resp_abcdefghijklmno",
        "short",
    ] {
        let row = usage(ROOT, TIME, id, 100);
        let file = write(
            dir.path(),
            "rollout-a.jsonl",
            ROOT,
            std::slice::from_ref(&row),
        );
        let record = &parse(&file)[0];
        assert_eq!(
            record["record_key"],
            format!("codex|{SESSION}|{ROOT}|{TIME}"),
            "{id}"
        );
        assert_eq!(record["replaces"], json!([format!("codex|{SESSION}|{id}")]));
        let mut without_thread = row;
        without_thread["payload"]
            .as_object_mut()
            .unwrap()
            .remove("thread_id");
        write(dir.path(), "rollout-a.jsonl", ROOT, &[without_thread]);
        assert_eq!(
            parse(&file)[0]["record_key"],
            format!(
                "codex|{SESSION}|{}:2",
                super::file_tag(file.to_str().unwrap())
            )
        );
    }
    let id = "resp_abcdefghijklmnop";
    let file = write(
        dir.path(),
        "rollout-a.jsonl",
        ROOT,
        &[usage(ROOT, TIME, id, 100)],
    );
    assert_eq!(
        parse(&file)[0]["record_key"],
        format!("codex|{SESSION}|{id}")
    );
}

#[test]
fn e1_fix1_partial_copy_of_reused_long_id_is_stable_across_syncs() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let mut first = usage(ROOT, TIME, LONG_ID, 100);
    first["payload"]["usage"]["output_tokens"] = json!(0);
    let mut second = usage(ROOT, "2026-01-14T10:01:00Z", LONG_ID, 200);
    second["payload"]["usage"]["output_tokens"] = json!(0);
    write(&home, "rollout-a.jsonl", ROOT, &[first.clone(), second]);
    write(&home, "rollout-b.jsonl", CHILD, &[first]);
    let mut samples = Vec::new();
    for _ in 0..2 {
        let run = sync(dir.path());
        let totals = ledger(dir.path()).totals(&json!({})).unwrap();
        samples.push(json!({"gross":totals["gross_tokens"],"records":totals["record_count"],"anomalies":run["anomalies"]}));
    }
    println!("fix1 partial-copy samples: {}", json!(samples));
    assert_eq!(
        samples
            .iter()
            .map(|s| s["gross"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [200, 200],
        "shape-only identity retains the last value of a reused long ID"
    );
    assert!(samples.iter().all(|s| s["records"] == 1));
    assert!(samples.iter().all(|s| s["anomalies"] == json!([])));
}

#[test]
fn e1_reused_long_id_keeps_old_key_and_updates_in_place() {
    for second in [
        usage(ROOT, "2026-01-14T10:01:00Z", LONG_ID, 100),
        usage(ROOT, TIME, LONG_ID, 200),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let file = write(
            &dir.path().join("home"),
            "rollout-a.jsonl",
            ROOT,
            &[usage(ROOT, TIME, LONG_ID, 100), second],
        );
        let records = parse(&file);
        let expected_key = format!("codex|{SESSION}|{LONG_ID}");
        for record in &records {
            assert_eq!(record["record_key"], expected_key);
            assert!(record.get("replaces").is_none());
        }
        let result = sync(dir.path());
        assert_eq!(result["inserted"], 1);
        assert_eq!(result["updated"], 1);
        assert_eq!(result["anomalies"], json!([]));
        let ledger = ledger(dir.path());
        let rows = ledger::rows(&ledger.db, "SELECT * FROM usage_records", &[]).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["record_key"], expected_key);
        assert_eq!(rows[0]["active"], 1);
        assert_eq!(rows[0]["revision"], 2);
        for field in [
            "observed_at",
            "input_tokens",
            "cache_read_tokens",
            "output_tokens",
        ] {
            assert_eq!(rows[0][field], records[1][field]);
        }
    }
}

#[test]
fn e1_v4_collision_migrates_one_old_row_to_three_active_requests() {
    let dir = tempfile::tempdir().unwrap();
    let owner = minimal(&dir.path().join("home"));
    let ledger = ledger(dir.path());
    // Frozen v4 identity rule and settle owner: A starts first; B loses the shared key.
    let mut v4 = parse(&owner);
    let old_key = format!("codex|{SESSION}|resp_0");
    for record in &mut v4 {
        record["record_key"] = json!(old_key);
        record.as_object_mut().unwrap().remove("replaces");
    }
    ledger
        .batch(
            &v4,
            Some(owner.to_str().unwrap()),
            Some(4),
            &[],
            pricing::cost_of,
        )
        .unwrap();
    assert_eq!(ledger.totals(&json!({})).unwrap()["gross_tokens"], 220);
    drop(ledger);
    let result = sync(dir.path());
    assert_eq!(result["inserted"], 3);
    assert_eq!(result["counts"]["replaced"], 1);
    let ledger = self::ledger(dir.path());
    let rows = ledger::rows(&ledger.db, "SELECT * FROM usage_records ORDER BY id", &[]).unwrap();
    assert_eq!(rows.len(), 4);
    assert_eq!(rows[0]["record_key"], old_key);
    assert_eq!(rows[0]["active"], 0);
    assert_eq!(rows[0]["superseded_by"], rows[1]["id"]);
    assert!(rows[1..]
        .iter()
        .all(|r| r["active"] == 1 && r["parser_rev"] == 5));
    assert_eq!(ledger.totals(&json!({})).unwrap()["gross_tokens"], 660);
    assert_eq!(
        service::summary(&ledger, &json!({}), 0, "UTC").unwrap()["totals"]["gross_tokens"],
        660
    );
    drop(ledger);
    let client = crate::api::stats::StatsClient::new_with_fixed_clock(
        dir.path().join("data").to_string_lossy().into_owned(),
        Some(dir.path().join("home").to_string_lossy().into_owned()),
        1768478400000,
    )
    .unwrap();
    assert_eq!(
        client
            .summary(crate::api::stats::StatsFilter::default(), 0)
            .unwrap()
            .totals
            .gross_tokens,
        660
    );
    assert_eq!(sync(dir.path())["inserted"], 0);
    assert_eq!(
        self::ledger(dir.path())
            .db
            .query_row("SELECT count(*) FROM usage_records", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        4
    );
}

#[test]
fn e1_jsonl_zstd_replacement_preserves_all_identity_branches() {
    let dir = tempfile::tempdir().unwrap();
    let mut no_thread = usage(ROOT, TIME, "resp_0", 100);
    no_thread["payload"]
        .as_object_mut()
        .unwrap()
        .remove("thread_id");
    let mut no_id = no_thread.clone();
    no_id["payload"]
        .as_object_mut()
        .unwrap()
        .remove("response_id");
    let file = write(
        &dir.path().join("home"),
        "rollout-a.jsonl",
        ROOT,
        &[
            usage(ROOT, TIME, LONG_ID, 100),
            usage(ROOT, TIME, "resp_0", 200),
            usage(ROOT, TIME, "resp_0", 300),
            no_thread,
            no_id,
        ],
    );
    let before = parse(&file);
    sync(dir.path());
    let before_totals = ledger(dir.path()).totals(&json!({})).unwrap();
    // A standard Zstandard frame with one raw block, decoded by the production multi-frame reader.
    let bytes = fs::read(&file).unwrap();
    let mut frame = vec![0x28, 0xb5, 0x2f, 0xfd, 0xa0];
    frame.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    frame.extend_from_slice(&((bytes.len() as u32 * 8) | 1).to_le_bytes()[..3]);
    frame.extend_from_slice(&bytes);
    let compressed = file.with_extension("jsonl.zst");
    fs::rename(&file, &compressed).unwrap();
    fs::write(&compressed, frame).unwrap();
    assert_eq!(parse(&compressed), before);
    let result = sync(dir.path());
    assert_eq!(result["inserted"], 0);
    assert_eq!(result["updated"], 0);
    assert_eq!(result["unchanged"], 5);
    assert_eq!(result["anomalies"], json!([]));
    let ledger = ledger(dir.path());
    assert_eq!(ledger.totals(&json!({})).unwrap(), before_totals);
    let rows = ledger::rows(
        &ledger.db,
        "SELECT source_file FROM usage_records WHERE active=1",
        &[],
    )
    .unwrap();
    assert!(rows
        .iter()
        .all(|r| r["source_file"] == compressed.to_str().unwrap()));
}
