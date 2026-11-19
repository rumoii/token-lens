use super::super::{clock::Clock, ingest, ledger::Ledger, service};
use super::{parse, LocalZone};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::{fs, path::Path, sync::atomic::AtomicBool};

pub(crate) const SESSION_PATH: &str = ".gemini/antigravity-cli/conversations/synthetic.db";
const SUMMARIES_PATH: &str = ".gemini/antigravity-cli/conversation_summaries.db";
const START: u64 = 1_768_478_400;
const CLOCK: Clock = Clock::Fixed(1_768_478_400_000);
const ZONE: LocalZone = LocalZone::Fixed(480);

fn varint(mut n: u64) -> Vec<u8> {
    let mut bytes = Vec::new();
    while n >= 128 {
        bytes.push(n as u8 | 128);
        n >>= 7;
    }
    bytes.push(n as u8);
    bytes
}

fn number(tag: u64, n: u64) -> Vec<u8> {
    [varint(tag << 3), varint(n)].concat()
}

fn bytes(tag: u64, body: impl AsRef<[u8]>) -> Vec<u8> {
    let body = body.as_ref();
    [
        varint(tag << 3 | 2),
        varint(body.len() as u64),
        body.to_vec(),
    ]
    .concat()
}

fn attr(key: &str, value: &str) -> Vec<u8> {
    bytes(20, [bytes(1, key), bytes(2, value)].concat())
}

fn generation(request: &str, step: Option<i64>, usage: Option<Vec<u8>>) -> Vec<u8> {
    let mut body = bytes(19, "fixture-model");
    if !request.is_empty() {
        body.extend(attr("request_id", request));
    }
    if let Some(step) = step {
        body.extend(attr("last_step_index", &step.to_string()));
    }
    if let Some(usage) = usage {
        body.extend(bytes(4, usage));
    }
    // Unused attributes, fixed fields and sibling messages must be skipped.
    body.extend(attr("used_claude", "true"));
    body.extend([varint(30 << 3 | 5), vec![0; 4]].concat());
    [bytes(3, bytes(28, "fixture-model-high")), bytes(1, body)].concat()
}

fn insert(db: &Connection, idx: i64, data: Vec<u8>) {
    db.execute(
        "INSERT INTO gen_metadata VALUES (?1, ?2, length(?2))",
        params![idx, data],
    )
    .unwrap();
}

fn timestamp(tag: u64, seconds: u64) -> Vec<u8> {
    bytes(tag, [number(1, seconds), number(2, 987)].concat())
}

fn step(db: &Connection, idx: i64, kind: i64, metadata: Vec<u8>) {
    db.execute(
        "INSERT INTO steps(idx, step_type, metadata) VALUES (?1, ?2, ?3)",
        params![idx, kind, metadata],
    )
    .unwrap();
}

fn session(home: &Path) -> Connection {
    let path = home.join(SESSION_PATH);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
         CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);
         CREATE TABLE steps(idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB, step_payload BLOB);
         CREATE TABLE trajectory_metadata_blob(id INTEGER PRIMARY KEY, data BLOB);",
    )
    .unwrap();
    db
}

fn summaries(home: &Path, entry: Option<(&str, &str)>) {
    let path = home.join(SUMMARIES_PATH);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch(
        "CREATE TABLE projects(conversation_id TEXT PRIMARY KEY, workspace_uris TEXT);
         CREATE VIEW conversation_summaries AS SELECT conversation_id, workspace_uris,
            json_extract('invalid JSON', '$') AS title,
            json_extract('invalid JSON', '$') AS preview,
            json_extract('invalid JSON', '$') AS raw_summary FROM projects;",
    )
    .unwrap();
    if let Some((id, uris)) = entry {
        db.execute(
            "INSERT INTO projects(conversation_id,workspace_uris) VALUES (?1,?2)",
            params![id, uris],
        )
        .unwrap();
    }
}

fn usage(input: u64, output: u64) -> Vec<u8> {
    [number(2, input), number(3, output)].concat()
}

pub(crate) fn seed(home: &Path) -> Connection {
    let db = session(home);
    step(&db, 1, 15, timestamp(1, START + 1));
    insert(
        &db,
        0,
        generation("request-a", Some(0), Some(usage(300, 27))),
    );
    db
}

fn parsed(home: &Path) -> (Vec<Value>, Value) {
    parse("antigravity", SESSION_PATH, &home.join(SESSION_PATH), &ZONE).unwrap()
}

fn sync(home: &Path, data: &Path) -> Value {
    ingest::sync(
        data,
        home,
        &ingest::Environment::default().preview(),
        CLOCK,
        &ZONE,
        &AtomicBool::new(false),
    )
    .unwrap()
}

fn workspace() -> (&'static str, &'static str) {
    if cfg!(windows) {
        (
            "file:///D:/Synthetic%20Workspace/",
            r"D:\Synthetic Workspace",
        )
    } else {
        (
            "file:///tmp/Synthetic%20Workspace/",
            "/tmp/Synthetic Workspace",
        )
    }
}

#[test]
fn antigravity_two_generations_match_native_expected_records() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let db = seed(home);
    let (uri, project) = workspace();
    summaries(
        home,
        Some((
            "synthetic",
            &json!(["https://invalid.example", uri, "file:///other"]).to_string(),
        )),
    );
    step(&db, 3, 6, timestamp(1, START + 3));
    step(&db, 4, 15, timestamp(1, START + 4));
    step(&db, 5, 15, timestamp(1, START + 5));
    insert(
        &db,
        1,
        generation(
            "request-b",
            Some(2),
            Some(
                [
                    usage(90, 33),
                    number(5, 210),
                    number(6, 44),
                    number(9, 30),
                    number(10, 3),
                ]
                .concat(),
            ),
        ),
    );
    insert(
        &db,
        2,
        generation("incomplete", Some(2), Some(number(1, 7))),
    );
    insert(&db, 3, generation("no-usage", Some(2), None));
    let (records, notes) = parsed(home);
    assert_eq!(
        records,
        vec![
            json!({"record_key":"antigravity:request-a","source":"antigravity","kind":"event",
            "session_id":"synthetic","model":"fixture-model","provider":null,"project_key":project,
            "observed_at":"2026-01-15T12:00:01.000Z","input_tokens":300,"output_tokens":27,
            "cache_read_tokens":0,"cache_write_tokens":null}),
            json!({"record_key":"antigravity:request-b","source":"antigravity","kind":"event",
            "session_id":"synthetic","model":"fixture-model","provider":null,"project_key":project,
            "observed_at":"2026-01-15T12:00:04.000Z","input_tokens":90,"output_tokens":33,
            "cache_read_tokens":210,"cache_write_tokens":null})
        ]
    );
    assert_eq!(notes["zero_usage"], 1);
}

#[test]
fn antigravity_time_fallbacks_and_rejection() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let db = seed(&home);
    step(&db, 3, 6, timestamp(1, START + 3));
    insert(&db, 1, generation("", Some(2), Some(number(5, 9))));
    insert(&db, 2, generation("trajectory", None, Some(number(3, 4))));
    db.execute(
        "INSERT INTO trajectory_metadata_blob VALUES(0,?1)",
        [timestamp(2, START)],
    )
    .unwrap();
    let (records, _) = parsed(&home);
    assert_eq!(records.len(), 3);
    assert_eq!(records[0]["observed_at"], "2026-01-15T12:00:01.000Z");
    assert_eq!(records[1]["observed_at"], "2026-01-15T12:00:03.000Z");
    assert_eq!(records[1]["record_key"], "antigravity:synthetic:1");
    assert_eq!(records[1]["input_tokens"], 0);
    assert_eq!(records[1]["output_tokens"], 0);
    assert_eq!(records[1]["cache_read_tokens"], 9);
    assert_eq!(records[2]["observed_at"], "2026-01-15T12:00:00.000Z");
    db.execute("DELETE FROM trajectory_metadata_blob", [])
        .unwrap();
    let result = sync(&home, &data);
    assert_eq!(result["attempted"], 3);
    assert_eq!(result["inserted"], 2);
    assert_eq!(result["rejected"], 1);
    assert_eq!(result["counts"]["bad_times"], 1);
    assert!(result["anomalies"].as_array().unwrap().iter().any(|a| {
        a.as_str()
            .is_some_and(|note| note.contains("antigravity") && note.contains("observed_at"))
    }));
}

#[test]
fn antigravity_project_is_null_without_a_file_uri() {
    for entry in [
        None,
        Some(None),
        Some(Some(("other-session", "[\"file:///D:/other\"]"))),
        Some(Some(("synthetic", "[]"))),
        Some(Some(("synthetic", "[\"https://invalid.example\",null]"))),
        Some(Some(("synthetic", "malformed JSON"))),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let _db = seed(temp.path());
        if let Some(entry) = entry {
            summaries(temp.path(), entry);
        }
        let (records, _) = parsed(temp.path());
        assert_eq!(records.len(), 1);
        assert!(records[0]["project_key"].is_null(), "{entry:?}");
    }
}

#[test]
fn antigravity_damaged_blobs_skip_only_affected_rows() {
    let temp = tempfile::tempdir().unwrap();
    let db = seed(temp.path());
    insert(&db, 1, vec![0x0a, 0x80]);
    insert(
        &db,
        2,
        bytes(
            1,
            bytes(
                4,
                [
                    0x10, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2,
                ],
            ),
        ),
    );
    step(&db, 4, 15, vec![0x0a, 0x02, 0x08]);
    insert(&db, 3, generation("bad-step", Some(3), Some(usage(20, 1))));
    insert(&db, 4, generation("after-bad", Some(0), Some(usage(26, 1))));
    let (records, notes) = parsed(temp.path());
    assert_eq!(notes["bad_lines"], 3);
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["record_key"], "antigravity:after-bad");
}

#[test]
fn antigravity_repeated_sync_reads_wal_and_appends_only_new_record() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let db = seed(&home);
    assert_eq!(
        service::discovery(&home, &ingest::Environment::default().preview())["sources"],
        json!([{"source":"antigravity","files":1}])
    );
    assert_eq!(sync(&home, &data)["inserted"], 1);
    let second = sync(&home, &data);
    assert_eq!(second["inserted"], 0);
    assert_eq!(second["updated"], 0);
    assert_eq!(second["unchanged"], 1);
    assert_eq!(second["parsedFiles"], 1);
    assert_eq!(second["cachedFiles"], 0);
    step(&db, 4, 15, timestamp(1, START + 4));
    insert(
        &db,
        1,
        generation("request-b", Some(2), Some(usage(90, 33))),
    );
    let third = sync(&home, &data);
    assert_eq!(third["inserted"], 1);
    assert_eq!(third["unchanged"], 1);
    let ledger = Ledger::open(&data.join("ledger.db"), CLOCK).unwrap();
    let count: i64 = ledger
        .db
        .query_row("SELECT count(*) FROM usage_records", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 2);
}
