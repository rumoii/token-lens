use super::*;
use std::fs;

struct Fixture {
    root: tempfile::TempDir,
    home: std::path::PathBuf,
    data: std::path::PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let data = root.path().join("data");
        Self { root, home, data }
    }

    fn file(&self, relative: &str, bytes: impl AsRef<[u8]>) -> std::path::PathBuf {
        let path = self.home.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        path
    }

    fn run(&self, zone: i32) -> Value {
        sync(
            &self.data,
            &self.home,
            &Environment::default(),
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(zone),
            &AtomicBool::new(false),
        )
        .unwrap()
    }

    fn ledger(&self) -> Ledger {
        Ledger::open(&self.data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap()
    }
}

const QWEN: &str = r#"{"sessionId":"synthetic","id":"request","timestamp":"2026-01-15T12:00:00","model":"qwen3-coder","inputTokens":100,"outputTokens":20,"apiDurationMs":800}"#;
const QWEN_PATH: &str = ".qwen/usage/token-usage-synthetic.jsonl";

#[cfg(windows)]
#[test]
fn system_timezone_allows_first_source_to_reuse_cache() {
    let fixture = Fixture::new();
    fixture.file(
        ".claude/projects/synthetic.jsonl",
        include_bytes!("../../../../test/fixtures/parity/ingest-a.jsonl"),
    );
    let run = || {
        sync(
            &fixture.data,
            &fixture.home,
            &Environment::default(),
            Clock::Fixed(1768478400000),
            &LocalZone::System,
            &AtomicBool::new(false),
        )
        .unwrap()
    };
    run();
    assert_eq!(run()["skippedFiles"], 1);
}

#[test]
fn unchanged_source_skips_parsing_and_all_batches() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, format!("{QWEN}\n{{\n"));
    let cold = fixture.run(0);
    let repeat = fixture.run(0);
    assert_eq!(cold["parsedFiles"], 1);
    assert_eq!(cold["counts"]["bad_lines"], 1);
    assert_eq!(repeat["fileCount"], 1);
    assert_eq!(repeat["skippedFiles"], 1);
    assert_eq!(repeat["parsedFiles"], 0);
    assert_eq!(repeat["attempted"], 0);
    assert_eq!(repeat["counts"]["bad_lines"], 0);
    let last = fixture.ledger().last_run().unwrap();
    assert_eq!(last["skipped_files"], 1);
}

#[test]
fn pending_replacement_reuses_cache_and_only_then_skips() {
    let fixture = Fixture::new();
    fixture.file(
        ".codex/sessions/rollout-replacement.jsonl",
        concat!(
            r#"{"type":"session_meta","payload":{"session_id":"test-session"}}"#, "\n",
            r#"{"type":"token_usage_record","timestamp":"2026-01-15T12:00:10Z","payload":{"turn_id":"resp_synthetic_000001_000000","usage":{"input_tokens":200,"output_tokens":20}}}"#, "\n",
            r#"{"type":"token_usage_record","timestamp":"2026-01-15T12:00:00Z","payload":{"response_id":"resp_synthetic_000001_000000","usage":{"input_tokens":100,"output_tokens":10}}}"#, "\n",
        ),
    );
    let cold = fixture.run(0);
    assert_eq!(cold["counts"]["replaced"], 0);
    let replay = fixture.run(0);
    assert_eq!(replay["counts"]["replaced"], 1);
    assert_eq!(replay["cachedFiles"], 1);
    assert_eq!(replay["parsedFiles"], 0);
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
}

#[test]
fn changed_file_replays_cached_notes_and_timezone_invalidates() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, format!("{QWEN}\n{{\n"));
    fixture.run(0);
    let added = QWEN.replace("\"request\"", "\"new-request\"");
    fixture.file(".qwen/usage/token-usage-new.jsonl", added);
    let changed = fixture.run(0);
    assert_eq!(changed["parsedFiles"], 1);
    assert_eq!(changed["cachedFiles"], 1);
    assert_eq!(changed["counts"]["bad_lines"], 1);
    assert_eq!(changed["attempted"], 2);
    let zone = fixture.run(60);
    assert_eq!(zone["parsedFiles"], 2);
    assert_eq!(zone["updated"], 2);
}

#[test]
fn new_ledger_installs_v7() {
    let fixture = Fixture::new();
    assert!(fixture.root.path().exists());
    let ledger = fixture.ledger();
    let version = ledger
        .db
        .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
        .unwrap();
    assert_eq!(version, 7);
}

#[test]
fn cached_cumulative_decrease_preserves_ledger_until_usage_revision_changes() {
    let fixture = Fixture::new();
    let export = |id: &str, tokens| {
        json!({"sessions":[{"session_id":id,"timestamp":"2026-01-15T12:00:00Z",
            "model":"deepseek-flash","input_token":tokens,"output_token":20}]})
        .to_string()
    };
    fixture.file("synthetic-trae.json", export("owner", 1000));
    fixture.run(0);
    fixture.file("synthetic-trae.json", export("owner", 100));
    let lower = fixture.run(0);
    assert_eq!(lower["counts"]["cumulative_decrease"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        1000
    );
    fixture.file("other-trae.json", export("other", 40));
    let replay = fixture.run(0);
    assert_eq!(replay["cachedFiles"], 1);
    assert_eq!(replay["counts"]["cumulative_decrease"], 1);
    let next = fixture.with_options(SyncOptions {
        revisions: Some(Revisions {
            usage: Some(adapters::parser_rev("trae") + 1),
            timing: adapters::timing_rev("trae"),
        }),
        ..Default::default()
    });
    assert_eq!(next["parsedFiles"], 2);
    assert_eq!(next["counts"]["rev_corrections"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records WHERE session_id='owner'")[0]
            ["input_tokens"],
        100
    );
}

#[test]
fn replay_uses_parsed_timing_and_writer_retains_or_replaces_group() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, QWEN);
    fixture.run(0);
    fixture.file(QWEN_PATH, QWEN.replace(",\"apiDurationMs\":800", ""));
    fixture.run(0);
    fixture.file(
        ".qwen/usage/token-usage-other.jsonl",
        QWEN.replace("\"request\"", "\"other\""),
    );
    let next = fixture.run(0);
    assert_eq!(next["cachedFiles"], 1);
    let timing = "SELECT duration_ms,timing_output_tokens FROM usage_timings WHERE record_key='qwen|synthetic|request'";
    assert_eq!(
        fixture.rows(timing),
        [json!({"duration_ms":800,"timing_output_tokens":20})]
    );
    fixture.file(
        QWEN_PATH,
        QWEN.replace("outputTokens\":20", "outputTokens\":25")
            .replace("800", "1050"),
    );
    assert_eq!(fixture.run(0)["updated"], 1);
    assert_eq!(
        fixture.rows(timing),
        [json!({"duration_ms":1050,"timing_output_tokens":25})]
    );
}
fn same_metadata_rewrite(path: &Path, bytes: &[u8]) {
    let metadata = fs::metadata(path).unwrap();
    assert_eq!(metadata.len(), bytes.len() as u64);
    fs::write(path, bytes).unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(metadata.modified().unwrap())
        .unwrap();
}

fn qwen_revisions() -> Revisions {
    Revisions {
        usage: Some(adapters::parser_rev("qwen")),
        timing: adapters::timing_rev("qwen"),
    }
}

impl Fixture {
    fn with_options(&self, options: SyncOptions) -> Value {
        sync_profiled(
            &self.data,
            &self.home,
            &Environment::default(),
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(0),
            &AtomicBool::new(false),
            options,
        )
        .unwrap()
        .0
    }

    fn rows(&self, sql: &str) -> Vec<Value> {
        super::super::ledger::rows(&self.ledger().db, sql, &[]).unwrap()
    }
}

#[test]
fn reread_detects_same_metadata_rewrite_and_rebuilds_cache() {
    let fixture = Fixture::new();
    let path = fixture.file(QWEN_PATH, QWEN);
    fixture.run(0);
    same_metadata_rewrite(&path, QWEN.replace("100", "200").as_bytes());
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        100
    );
    let reread = fixture.with_options(SyncOptions::new(true));
    assert_eq!(reread["parsedFiles"], 1);
    assert_eq!(reread["updated"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        200
    );
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
}

#[test]
fn usage_revision_reparses_and_deactivates_only_nonempty_missing_records() {
    let fixture = Fixture::new();
    let second = QWEN.replace("\"request\"", "\"removed\"");
    let path = fixture.file(QWEN_PATH, format!("{QWEN}\n{second}\n"));
    fixture.run(0);
    same_metadata_rewrite(
        &path,
        format!("{QWEN}\n{}\n", " ".repeat(second.len())).as_bytes(),
    );
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
    let mut revisions = qwen_revisions();
    revisions.usage = revisions.usage.map(|rev| rev + 1);
    let outcome = fixture.with_options(SyncOptions {
        revisions: Some(revisions),
        ..Default::default()
    });
    assert_eq!(outcome["parsedFiles"], 1);
    assert_eq!(outcome["counts"]["deactivated"], 1);
    assert_eq!(
        fixture.rows("SELECT active FROM usage_records ORDER BY record_key"),
        [json!({"active":0}), json!({"active":1})]
    );
    assert_eq!(
        fixture.rows("SELECT parser_rev,duration_ms FROM usage_timings"),
        [json!({"parser_rev": revisions.timing, "duration_ms":800})]
    );
}

#[test]
fn timing_revision_reparses_empty_output_and_revokes_timing_but_keeps_usage() {
    let fixture = Fixture::new();
    let path = fixture.file(QWEN_PATH, QWEN);
    fixture.run(0);
    assert_eq!(
        fixture.rows("SELECT duration_ms FROM usage_timings"),
        [json!({"duration_ms":800})]
    );
    same_metadata_rewrite(&path, " ".repeat(QWEN.len()).as_bytes());
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
    let mut revisions = qwen_revisions();
    revisions.timing = revisions.timing.map(|rev| rev + 1);
    let outcome = fixture.with_options(SyncOptions {
        revisions: Some(revisions),
        ..Default::default()
    });
    assert_eq!(outcome["parsedFiles"], 1);
    assert_eq!(outcome["attempted"], 0);
    assert_eq!(
        fixture.rows("SELECT active,parser_rev FROM usage_records"),
        [json!({"active":1,"parser_rev":revisions.usage})]
    );
    assert!(fixture.rows("SELECT * FROM usage_timings").is_empty());

    revisions.usage = revisions.usage.map(|rev| rev + 1);
    let outcome = fixture.with_options(SyncOptions {
        revisions: Some(revisions),
        ..Default::default()
    });
    assert_eq!(outcome["parsedFiles"], 1);
    assert_eq!(
        fixture.rows("SELECT active FROM usage_records"),
        [json!({"active":1})]
    );
}

#[test]
fn file_changed_during_parsing_uses_old_output_once_without_caching_it() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, QWEN);
    let first = fixture.with_options(SyncOptions {
        after_parse: Some(|path| fs::write(path, QWEN.replace("100", "20000")).unwrap()),
        ..Default::default()
    });
    assert_eq!(first["inserted"], 1);
    assert!(fixture.rows("SELECT path FROM ingest_files").is_empty());
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        100
    );
    assert_eq!(fixture.run(0)["parsedFiles"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        20000
    );
    assert_eq!(fixture.run(0)["skippedFiles"], 1);
}

#[test]
fn grok_sidecar_add_modify_remove_invalidates_unchanged_log() {
    let fixture = Fixture::new();
    fixture.file(
        ".grok/sessions/p/ledger/updates.jsonl",
        include_bytes!(
            "../../../../test/fixtures/parity/grok/.grok/sessions/p/ledger/updates.jsonl"
        ),
    );
    assert_eq!(fixture.run(0)["parsedFiles"], 1);
    let side = ".grok/sessions/p/ledger/summary.json";
    for (input, model) in [
        (r#"{"current_model_id":"grok-first"}"#, "grok-first"),
        (
            r#"{"current_model_id":"grok-second-model"}"#,
            "grok-second-model",
        ),
    ] {
        fixture.file(side, input);
        assert_eq!(fixture.run(0)["parsedFiles"], 1);
        assert_eq!(
            fixture.rows("SELECT model FROM usage_records")[0]["model"],
            model
        );
        assert_eq!(fixture.run(0)["skippedFiles"], 1);
    }
    fs::remove_file(fixture.home.join(side)).unwrap();
    assert_eq!(fixture.run(0)["parsedFiles"], 1);
    assert_eq!(
        fixture.rows("SELECT model FROM usage_records")[0]["model"],
        Value::Null
    );
}

#[test]
fn sqlite_wal_is_read_each_round_without_fingerprinting_main_file() {
    let fixture = Fixture::new();
    let path = fixture.file(".local/share/opencode/opencode.db", []);
    let source = rusqlite::Connection::open(&path).unwrap();
    source
        .execute_batch(include_str!(
            "../../../../test/fixtures/parity/opencode/ledger.sql"
        ))
        .unwrap();
    source
        .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        .unwrap();
    assert_eq!(fixture.run(0)["parsedFiles"], 1);
    let before = fs::metadata(&path).unwrap();
    source
        .execute(
            "UPDATE message SET data=replace(data,'\"input\":10','\"input\":22')",
            [],
        )
        .unwrap();
    let after = fs::metadata(&path).unwrap();
    assert_eq!(before.len(), after.len());
    assert_eq!(before.modified().unwrap(), after.modified().unwrap());
    let next = fixture.run(0);
    assert_eq!(next["parsedFiles"], 1);
    assert_eq!(next["updated"], 1);
    assert!(fixture.rows("SELECT path FROM ingest_files").is_empty());
}

#[test]
fn price_change_is_applied_when_all_logs_skip() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, QWEN);
    fixture.run(0);
    fixture
        .ledger()
        .db
        .execute("UPDATE usage_records SET price_version='test-old'", [])
        .unwrap();
    let next = fixture.run(0);
    assert_eq!(next["skippedFiles"], 1);
    assert_eq!(next["repriced"], 1);
    assert_eq!(
        fixture.rows("SELECT price_version FROM usage_records")[0]["price_version"],
        pricing::PRICE_VERSION
    );
}

#[test]
fn cache_write_error_rolls_back_usage_and_next_run_retries() {
    let fixture = Fixture::new();
    fixture.file(QWEN_PATH, QWEN);
    fixture.run(0);
    let ledger = fixture.ledger();
    let old = fixture.rows("SELECT fingerprint FROM ingest_files");
    fixture.file(QWEN_PATH, QWEN.replace("100", "20000"));
    ledger.db.execute_batch(
        "CREATE TRIGGER fail_cache AFTER UPDATE ON ingest_files BEGIN SELECT RAISE(ABORT,'synthetic cache write failure'); END;",
    ).unwrap();
    let error = sync(
        &fixture.data,
        &fixture.home,
        &Environment::default(),
        Clock::System,
        &LocalZone::Fixed(0),
        &AtomicBool::new(false),
    )
    .unwrap_err();
    assert!(error.0.contains("synthetic cache write failure"));
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        100
    );
    assert_eq!(fixture.rows("SELECT fingerprint FROM ingest_files"), old);
    assert_eq!(
        fixture.rows("SELECT source FROM ingest_pending_sources"),
        [json!({"source":"qwen"})]
    );
    ledger.db.execute_batch("DROP TRIGGER fail_cache").unwrap();
    assert_eq!(fixture.run(0)["updated"], 1);
    assert_eq!(
        fixture.rows("SELECT input_tokens FROM usage_records")[0]["input_tokens"],
        20000
    );
    assert!(fixture
        .rows("SELECT source FROM ingest_pending_sources")
        .is_empty());
}

#[test]
fn cancel_after_cache_write_rolls_back_cache_and_usage() {
    let fixture = Fixture::new();
    let ledger = fixture.ledger();
    let cancel = std::cell::Cell::new(false);
    let record = json!({"record_key":"qwen|test|abc","source":"qwen","observed_at":"2026-01-15T12:00:00.000Z","input_tokens":10});
    let cached = CachedFile {
        fingerprint: "synthetic".into(),
        payload: Vec::new(),
        replaces: vec!["qwen|test|old".into()],
    };
    let err = ledger
        .batch_with_commit(
            std::slice::from_ref(&record),
            (Some("test"), qwen_revisions(), &[]),
            pricing::cost_of,
            || cancel.get(),
            |transaction| {
                Ledger::write_ingest_file(transaction, "qwen", "test", Some(&cached))?;
                cancel.set(true);
                Ok(())
            },
        )
        .unwrap_err();
    assert_eq!(err.0, "cancelled");
    for table in [
        "usage_records",
        "usage_timings",
        "ingest_files",
        "ingest_file_replaces",
    ] {
        assert!(
            fixture.rows(&format!("SELECT * FROM {table}")).is_empty(),
            "{table}"
        );
    }
    let next = ledger
        .batch_with_commit(
            &[record],
            (Some("test"), qwen_revisions(), &[]),
            pricing::cost_of,
            || false,
            |transaction| Ledger::write_ingest_file(transaction, "qwen", "test", Some(&cached)),
        )
        .unwrap();
    assert_eq!(next["inserted"], 1);
    assert_eq!(
        fixture.rows("SELECT path FROM ingest_files"),
        [json!({"path":"test"})]
    );
}
