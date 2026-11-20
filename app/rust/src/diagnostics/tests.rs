use super::*;
use crate::stats::{clock::Clock, ingest::Environment, ledger::Ledger};
use fs2::FileExt;
use std::time::Instant;
use writer::WRITER;

fn wait_for_logs() {
    assert!(flush_runtime_log(StdDuration::from_secs(5)));
}

#[test]
fn s6a_second_news_client_reports_already_running() {
    use crate::api::news::NewsClient;

    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().to_string_lossy().into_owned();
    let first = NewsClient::new(data.clone()).unwrap();
    let error = NewsClient::new(data).err().unwrap();
    assert!(error.starts_with("already_running:"), "{error}");
    drop(first);
}

#[test]
fn s6a_stats_open_classifies_corrupt_ledger() {
    let temp = tempfile::tempdir().unwrap();
    fs::write(temp.path().join("ledger.db"), "not a ledger").unwrap();
    let error = crate::api::stats::StatsClient::new(
        temp.path().to_string_lossy().into_owned(),
        Some(temp.path().to_string_lossy().into_owned()),
    )
    .err()
    .unwrap();
    assert!(error.starts_with("ledger_corrupt:"), "{error}");
}

#[test]
fn s6a_stats_open_refuses_newer_ledger_with_both_versions_before_writing() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("ledger.db");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.pragma_update(None, "user_version", 8).unwrap();
    drop(db);
    let before = fs::read(&path).unwrap();
    let error = crate::api::stats::StatsClient::new(
        temp.path().to_string_lossy().into_owned(),
        Some(temp.path().to_string_lossy().into_owned()),
    )
    .err()
    .unwrap();
    assert!(
        fs::read(&path).unwrap() == before,
        "database bytes changed: {error}"
    );
    assert!(error.starts_with("ledger_too_new:8:7: "), "{error}");
}

#[test]
fn s6a_typed_io_and_sqlite_errors_keep_their_category() {
    use crate::stats::Error;
    use rusqlite::ffi;
    use std::io::{self, ErrorKind};

    for (error, code) in [
        (
            io::Error::from(ErrorKind::PermissionDenied),
            "data_dir_denied",
        ),
        (io::Error::from(ErrorKind::StorageFull), "disk_full"),
    ] {
        assert_eq!(error_kind(&Error::from(error).0), code);
    }
    for (result, code) in [
        (ffi::SQLITE_FULL, "disk_full"),
        (ffi::SQLITE_READONLY, "data_dir_denied"),
        (ffi::SQLITE_PERM, "data_dir_denied"),
        (ffi::SQLITE_CORRUPT, "ledger_corrupt"),
        (ffi::SQLITE_NOTADB, "ledger_corrupt"),
        (ffi::SQLITE_CANTOPEN, "operation_failed"),
    ] {
        let error = rusqlite::Error::SqliteFailure(ffi::Error::new(result), None);
        assert_eq!(error_kind(&Error::from(error).0), code);
    }
    #[cfg(windows)]
    assert_eq!(
        error_kind(&Error::from(io::Error::from_raw_os_error(112)).0),
        "disk_full"
    );
    let cannot_open = rusqlite::Error::SqliteFailure(ffi::Error::new(ffi::SQLITE_CANTOPEN), None);
    assert_eq!(
        error_kind(
            &Error::sqlite(
                cannot_open,
                Some(&io::Error::from(ErrorKind::PermissionDenied))
            )
            .0
        ),
        "data_dir_denied"
    );
}

#[test]
fn s6a_error_kind_recognizes_startup_codes_and_preserves_legacy_codes() {
    for code in [
        "already_running",
        "app_files_missing",
        "data_dir_denied",
        "disk_full",
        "ledger_corrupt",
        "ledger_too_new",
        "startup_failed",
        "SYNC_BUSY",
        "LEGACY_SYNC_LOCK",
        "INVALID_RANGE",
        "INVALID_PARAM",
    ] {
        assert_eq!(error_kind(&format!("{code}: detail")), code);
    }
    assert_eq!(error_kind("cancelled"), "cancelled");
    assert_eq!(error_kind("closed"), "closed");
    assert_eq!(error_kind("unclassified error"), "operation_failed");
}

fn s6a_export(data: &Path, home: &Path, destination: &Path, code: &str) -> String {
    let path = crate::api::diagnostics::export_startup_diagnostics(
        Some(data.to_string_lossy().into_owned()),
        Some(home.to_string_lossy().into_owned()),
        destination.to_string_lossy().into_owned(),
        code.into(),
        format!("failed to read {}", home.join("private-file").display()),
    )
    .unwrap();
    let path = PathBuf::from(path);
    assert!(chrono::NaiveDateTime::parse_from_str(
        path.file_name().unwrap().to_str().unwrap(),
        "token-lens-diagnostics-%Y%m%d-%H%M%S.txt",
    )
    .is_ok());
    let text = fs::read_to_string(path).unwrap();
    assert!(!text.contains(&*home.to_string_lossy()), "{text}");
    text
}

#[test]
fn s6a_export_can_read_logs_and_discovery_with_a_corrupt_ledger() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("private-home");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    fs::write(logs.join("sample.jsonl"), "PRIVATE_CONVERSATION").unwrap();
    let data = home.join("data");
    fs::create_dir(&data).unwrap();
    let path = data.join("ledger.db");
    fs::write(&path, "PRIVATE_CORRUPT_LEDGER").unwrap();
    let log = RuntimeLog::new(&data, Some(&home));
    log.write("INFO", "test", "recent runtime event");
    log.write_at(
        Local::now() - Duration::days(7),
        "INFO",
        "test",
        "old runtime event",
    );
    let text = s6a_export(&data, &home, &temp.path().join("exports"), "ledger_corrupt");
    for fragment in [
        "Token Lens 诊断日志",
        "[应用]",
        "version=",
        "commit=",
        "os=",
        "data-dir=~",
        "code=ledger_corrupt",
        "failed to read ~",
        "账本：无法打开（ledger_corrupt）",
        "source=claude files=1",
        "[运行日志]",
        "recent runtime event",
    ] {
        assert!(text.contains(fragment), "missing {fragment}: {text}");
    }
    assert!(!text.contains("PRIVATE_CONVERSATION"));
    assert!(!text.contains("PRIVATE_CORRUPT_LEDGER"));
    assert!(!text.contains("old runtime event"));
    assert_eq!(fs::read(&path).unwrap(), b"PRIVATE_CORRUPT_LEDGER");
    assert_eq!(fs::read_dir(&data).unwrap().count(), 2);
}

#[test]
fn s6a_export_never_creates_a_missing_ledger_or_data_directory() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir(&home).unwrap();
    let existing = home.join("existing");
    fs::create_dir(&existing).unwrap();
    let missing = home.join("missing");
    for (index, data) in [&existing, &missing].into_iter().enumerate() {
        let text = s6a_export(
            data,
            &home,
            &temp.path().join(format!("exports-{index}")),
            "data_dir_denied",
        );
        assert!(text.contains("账本：无法打开（startup_failed）"));
        assert!(!data.join("ledger.db").exists());
    }
    assert!(!missing.exists());
    assert_eq!(fs::read_dir(&existing).unwrap().count(), 0);
}

#[test]
fn s6a_export_reads_ten_sync_runs_from_a_current_ledger() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = home.join("data");
    let path = data.join("ledger.db");
    let ledger = Ledger::open(&path, Clock::Fixed(1768478400000)).unwrap();
    for _ in 0..12 {
        let id = ledger.begin_run().unwrap();
        ledger.fail_run(id, "disk_full: raw detail").unwrap();
    }
    drop(ledger);
    let before = fs::read(&path).unwrap();
    let text = s6a_export(
        &data,
        &home,
        &temp.path().join("exports"),
        "already_running",
    );
    assert!(text.contains("schema=7"));
    assert_eq!(text.matches("run id=").count(), 10);
    assert!(text.contains("run id=3 "));
    assert!(text.contains("run id=12 "));
    assert!(text.contains("run_failed: disk_full"));
    assert!(!text.contains("raw detail"));
    assert_eq!(fs::read(path).unwrap(), before);
}

#[test]
fn s6a_export_declines_newer_ledger_without_modifying_it() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir(&home).unwrap();
    let path = home.join("ledger.db");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.pragma_update(None, "user_version", 8).unwrap();
    drop(db);
    let before = fs::read(&path).unwrap();
    let text = s6a_export(&home, &home, &temp.path().join("exports"), "ledger_too_new");
    assert!(text.contains("账本：无法打开（ledger_too_new）"));
    assert_eq!(fs::read(path).unwrap(), before);
    assert_eq!(fs::read_dir(&home).unwrap().count(), 1);
}

#[test]
fn s6a_settings_export_preserves_its_text_bytes() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = home.join("data");
    fs::create_dir_all(&data).unwrap();
    let ledger = Ledger::open(Path::new(":memory:"), Clock::System).unwrap();
    let file = RuntimeLog::new(&data, Some(&home))
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let text = fs::read_to_string(file).unwrap();
    let generated = text
        .lines()
        .nth(2)
        .unwrap()
        .strip_prefix("generated=")
        .unwrap();
    chrono::DateTime::parse_from_rfc3339(generated).unwrap();
    let environment = Environment::default();
    let mut expected = format!(
        "Token Lens 诊断日志\n[应用]\ngenerated={generated}\nversion={}\ncommit={}\nos={}\ndata-dir=~{}data\nschema=7\n\n[最近同步]\n\n[来源]\n",
        env!("CARGO_PKG_VERSION"),
        option_env!("TOKEN_LENS_BUILD_COMMIT").unwrap_or("unavailable"),
        os_version(),
        std::path::MAIN_SEPARATOR,
    );
    for (source, files) in discovery::discover_with_env(&home, &environment).unwrap() {
        assert!(files.is_empty());
        expected.push_str(&format!(
            "source={source} files=0 latest-file-mtime=unknown records=0 last-record=unknown\n"
        ));
        for root in discovery::scan_roots(&home, &environment, &source) {
            expected.push_str(&format!("  scan-root={}\n", root.display()));
        }
    }
    expected.push_str("\n[运行日志]\n");
    let expected = redact_home(&expected, Some(&home));
    assert_eq!(text, expected);
}
use chrono::{Duration, Local};
use std::{fs, sync::Arc};

// Deliberate lock contention must not consume other parallel tests' logging budget.
fn run_lock_test_in_child(name: &str) -> bool {
    const CHILD: &str = "TOKEN_LENS_E2_LOCK_TEST_CHILD";
    if std::env::var(CHILD).is_ok_and(|child| child == name) {
        return false;
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture"])
        .env(CHILD, name)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    true
}

#[test]
fn integration_fix2_v5_open_is_quiet_and_migration_is_logged() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("ledger.db");
    drop(Ledger::open(&path, Clock::System).unwrap());
    for _ in 0..2 {
        drop(Ledger::open(&path, Clock::System).unwrap());
    }
    wait_for_logs();
    let text = fs::read_to_string(temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    )))
    .unwrap();
    assert!(text.contains("migration schema=0->5"));
    assert!(
        !text.contains("open schema="),
        "v5 open must not create a log line"
    );
}

#[test]
fn integration_fix1_sensitive_home_is_private_in_logs_and_export() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("alice-sk-private");
    let data = temp.path().join("data");
    fs::create_dir_all(&home).unwrap();
    let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
    let log = RuntimeLog::new(&data, Some(&home));
    let native = home.to_string_lossy();
    log.flutter_error(
        &format!("{native}/ErrorType"),
        &format!("{native}/message prompt=PRIVATE_MESSAGE"),
        &format!("#0 frame ({native}/trace.dart:12:3)"),
    );
    log.ffi::<()>(&format!("{native}/ffi"), Err("closed".into()))
        .unwrap_err();
    log.write(
        "ERROR",
        "news",
        &format!("refresh source={native}/source kind=sk-PRIVATE_NEWS"),
    );
    let note = format!("read_failed: codex {native}/rollout.jsonl — PRIVATE_PARSE");
    log.write("WARN", "sync", &safe_anomaly(&note, &[]));
    let run = ledger.begin_run().unwrap();
    ledger
        .finish_run(
            run,
            "ok",
            &serde_json::json!({
                "attempted":0,"inserted":0,"updated":0,"unchanged":0,"rejected":0,
                "counts":{},"anomalies":[note]
            }),
        )
        .unwrap();
    let daily = data.join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    // Also cover exporting a log written before this sanitization order was fixed.
    wait_for_logs();
    writeln!(
        OpenOptions::new().append(true).open(&daily).unwrap(),
        "legacy {native}/old.dart:12:3 sk-PRIVATE_OLD"
    )
    .unwrap();
    let path = log
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let exported = fs::read_to_string(path).unwrap();
    assert!(
        !exported.contains("alice"),
        "username prefix leaked in export"
    );
    assert!(!exported.contains("PRIVATE_OLD"));
    // Check only logger-written lines; the deliberately appended legacy line is raw.
    let logged = fs::read_to_string(daily).unwrap();
    let logged = logged
        .lines()
        .filter(|line| !line.starts_with("legacy "))
        .collect::<Vec<_>>()
        .join("\n");
    for text in [&logged, &exported] {
        assert!(!text.contains("alice"), "username prefix leaked: {text}");
        assert!(!text.contains("PRIVATE_MESSAGE"));
        assert!(!text.contains("PRIVATE_NEWS"));
        assert!(!text.contains("PRIVATE_PARSE"));
        assert!(text.contains("~/trace.dart:12:3"));
        assert!(text.contains("~/ffi: closed"));
        assert!(text.contains("source=~/source"));
        assert!(text.contains("path=~/rollout.jsonl"));
    }
}

#[test]
fn integration_fix1_long_temp_keeps_error_truncation_test_valid() {
    let temp = tempfile::tempdir().unwrap();
    let long_temp = temp.path().join("long-temp-".repeat(8));
    fs::create_dir_all(&long_temp).unwrap();
    assert!(long_temp.to_string_lossy().chars().count() > 72);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "diagnostics::tests::e2_fix2_home_is_redacted_before_error_fields_are_shortened",
            "--nocapture",
        ])
        .env("TEMP", &long_temp)
        .env("TMP", &long_temp)
        .env("TMPDIR", &long_temp)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn e2_fix2_home_is_redacted_before_error_fields_are_shortened() {
    let temp = tempfile::tempdir().unwrap();
    let username = "PrivateUsername".repeat(10);
    // Only used for redaction, so keep the cutoff independent of the real TEMP path.
    let prefix = if cfg!(windows) { "C:/Users/" } else { "/home/" };
    let home = PathBuf::from(format!("{prefix}{username}"));
    let log = RuntimeLog::new(temp.path(), Some(&home));
    let native = home.to_string_lossy();
    for (field, limit) in [("type", 80), ("message", 200)] {
        // Place the old cutoff eight characters into the username.
        let before_username = prefix.chars().count();
        let padding = "x".repeat(limit - before_username - 8);
        let value = format!("{padding}{native}/trace");
        if field == "type" {
            log.flutter_error(&value, "safe", "");
        } else {
            log.flutter_error("StateError", &value, "");
        }
    }
    wait_for_logs();
    let text = fs::read_to_string(temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    )))
    .unwrap();
    assert!(!text.contains(&username[..4]), "username prefix leaked");
    assert!(text.contains("~/trace"));
    for line in text.lines() {
        let (kind, rest) = line.split_once("type=").unwrap();
        assert!(kind.contains("ERROR flutter"));
        let (kind, rest) = rest.split_once(" message=").unwrap();
        assert!(kind.chars().count() <= 80);
        assert!(rest.split_once(" stack=").unwrap().0.chars().count() <= 200);
    }
}

#[test]
fn diag_log_in_process_lock_does_not_delay_or_drop() {
    use std::sync::mpsc;
    if run_lock_test_in_child("diagnostics::tests::diag_log_in_process_lock_does_not_delay_or_drop")
    {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    let guard = WRITER.lock().unwrap_or_else(|p| p.into_inner());
    let (send, receive) = mpsc::channel();
    let worker_log = log.clone();
    let worker = std::thread::spawn(move || {
        let started = Instant::now();
        worker_log.write("INFO", "test", "retained under contention");
        send.send(started.elapsed()).unwrap();
    });
    let returned = receive.recv_timeout(StdDuration::from_millis(450));
    let directory_exists_while_locked = temp.path().join("logs").exists();
    drop(guard);
    worker.join().unwrap();
    assert!(
        returned.is_ok(),
        "logging waited indefinitely for the process mutex"
    );
    assert!(returned.unwrap() < StdDuration::from_millis(400));
    assert!(!directory_exists_while_locked);
    log.write("INFO", "test", "recovered");
    wait_for_logs();
    let text = fs::read_to_string(temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    )))
    .unwrap();
    assert!(text.contains("recovered"));
    assert_eq!(text.matches("retained under contention").count(), 1);
}

#[test]
fn diag_log_concurrent_writes_survive_a_stalled_writer() {
    if run_lock_test_in_child(
        "diagnostics::tests::diag_log_concurrent_writes_survive_a_stalled_writer",
    ) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    let now = Local::now();
    let guard = WRITER.lock().unwrap_or_else(|error| error.into_inner());
    let (finished, completions) = std::sync::mpsc::channel();
    std::thread::scope(|scope| {
        for worker in 0..8 {
            let log = &log;
            let finished = finished.clone();
            scope.spawn(move || {
                for line in 0..4 {
                    log.write_at(now, "INFO", "parallel", &format!("{worker}/{line}"));
                }
                finished.send(()).unwrap();
            });
        }
        let started = Instant::now();
        let deadline = started + StdDuration::from_secs(3);
        let finished_while_locked = (0..8).all(|_| {
            completions
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .is_ok()
        });
        std::thread::sleep(StdDuration::from_millis(250).saturating_sub(started.elapsed()));
        drop(guard);
        assert!(finished_while_locked);
    });
    wait_for_logs();
    let text = fs::read_to_string(
        temp.path()
            .join(format!("logs/token-lens-{}.log", now.format("%Y-%m-%d"))),
    )
    .unwrap();
    let lines: Vec<_> = text
        .lines()
        .filter_map(|line| line.split_once(" INFO parallel ").map(|(_, entry)| entry))
        .collect();
    assert_eq!(lines.len(), 32, "{text}");
    for worker in 0..8 {
        let prefix = format!("{worker}/");
        assert_eq!(
            lines
                .iter()
                .filter_map(|line| line.strip_prefix(&prefix))
                .collect::<Vec<_>>(),
            ["0", "1", "2", "3"]
        );
    }
}

#[test]
fn diag_log_runtime_exit_flushes_before_returning() {
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    for n in 0..32 {
        log.write("INFO", "test", &format!("before exit #{n}"));
    }
    crate::api::diagnostics::runtime_exit(temp.path().to_str().unwrap().into(), None);
    let mut paths: Vec<_> = fs::read_dir(temp.path().join("logs"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| log_date(path).is_some())
        .collect();
    paths.sort();
    let text = paths
        .iter()
        .map(|path| fs::read_to_string(path).unwrap())
        .collect::<String>();
    assert_eq!(text.matches(" INFO test before exit #").count(), 32);
    assert!(text.ends_with(" INFO app exit\n"));
}

#[test]
fn diag_log_queue_byte_budget_includes_pending_batches() {
    if run_lock_test_in_child(
        "diagnostics::tests::diag_log_queue_byte_budget_includes_pending_batches",
    ) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let directory = temp.path().join("logs");
    let now = Local::now();
    let text = format!("{}\n", "x".repeat(4 * 1024 * 1024 - 1)).into_boxed_str();
    let guard = WRITER.lock().unwrap_or_else(|error| error.into_inner());
    for days in (0..4).rev() {
        writer::submit(writer::LogLine {
            directory: directory.clone(),
            date: now - Duration::days(days),
            text: Some(text.clone()),
        })
        .unwrap();
    }
    drop(guard);
    wait_for_logs();
    let first = directory.join(format!(
        "token-lens-{}.log",
        (now - Duration::days(3)).format("%Y-%m-%d")
    ));
    let todays = directory.join(format!("token-lens-{}.log", now.format("%Y-%m-%d")));
    assert!(!todays.exists());
    assert_eq!(
        fs::read_dir(&directory)
            .unwrap()
            .flatten()
            .filter(|entry| log_date(&entry.path()).is_some())
            .count(),
        3
    );
    assert!(fs::read_to_string(first)
        .unwrap()
        .contains(" WARN runtime dropped 1 runtime log lines (queue full)"));
}

#[cfg(any(windows, unix))]
#[test]
fn diag_log_skips_linked_directories_lock_files_and_daily_logs() {
    #[cfg(unix)]
    use std::os::unix::fs::symlink as link_path;
    #[cfg(unix)]
    use std::os::unix::fs::symlink as link_dir;
    #[cfg(windows)]
    use std::os::windows::fs::symlink_dir as link_dir;
    #[cfg(windows)]
    use std::os::windows::fs::symlink_file as link_path;

    let temp = tempfile::tempdir().unwrap();
    let destination = temp.path().join("destination");
    fs::create_dir(&destination).unwrap();
    let data = temp.path().join("data");
    link_dir(&destination, &data).unwrap();
    let log = RuntimeLog::new(&data, None);
    log.write("INFO", "test", "blocked at a linked ancestor");
    wait_for_logs();
    assert_eq!(fs::read_dir(&destination).unwrap().count(), 0);

    let log = RuntimeLog::new(temp.path(), None);
    let directory = temp.path().join("logs");
    fs::create_dir(&directory).unwrap();
    let sentinel = destination.join("sentinel");
    fs::write(&sentinel, "untouched\n").unwrap();
    let lock = directory.join(".writer.lock");
    link_path(&sentinel, &lock).unwrap();
    log.write("INFO", "test", "blocked at a linked lock file");
    wait_for_logs();
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
    fs::remove_file(lock).unwrap();

    let now = Local::now();
    let daily = directory.join(format!("token-lens-{}.log", now.format("%Y-%m-%d")));
    let expired = directory.join(format!(
        "token-lens-{}.log",
        (now - Duration::days(8)).format("%Y-%m-%d")
    ));
    link_path(&sentinel, &daily).unwrap();
    link_path(&sentinel, &expired).unwrap();
    log.write_at(now, "INFO", "test", "blocked at a linked daily file");
    wait_for_logs();
    assert!(fs::symlink_metadata(expired).unwrap().is_symlink());
    assert_eq!(fs::read_to_string(sentinel).unwrap(), "untouched\n");
}

#[test]
fn diag_log_full_queue_warns_after_another_process_unlocks() {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};

    const NAME: &str =
        "diagnostics::tests::diag_log_full_queue_warns_after_another_process_unlocks";
    const HOLDER: &str = "TOKEN_LENS_DIAG_LOG_LOCK_HOLDER";
    if let Some(path) = std::env::var_os(HOLDER) {
        let lock = OpenOptions::new().write(true).open(path).unwrap();
        FileExt::try_lock_exclusive(&lock).unwrap();
        println!("diagnostic lock acquired");
        std::io::stdin().read_to_end(&mut Vec::new()).unwrap();
        return;
    }
    if run_lock_test_in_child(NAME) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    let directory = temp.path().join("logs");
    fs::create_dir(&directory).unwrap();
    let lock = directory.join(".writer.lock");
    fs::File::create(&lock).unwrap();
    let mut holder = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", NAME, "--nocapture", "--quiet"])
        .env(HOLDER, &lock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(holder.stdout.take().unwrap());
    assert!(stdout
        .by_ref()
        .lines()
        .any(|line| { line.unwrap().trim() == "diagnostic lock acquired" }));

    let now = Local::now();
    for n in 0..writer::QUEUE_LINES + 3 {
        log.write_at(now, "INFO", "test", &format!("queued #{n}"));
    }
    assert!(!flush_runtime_log(StdDuration::from_millis(250)));
    let daily = directory.join(format!("token-lens-{}.log", now.format("%Y-%m-%d")));
    assert!(!daily.exists());
    drop(holder.stdin.take());
    assert!(holder.wait().unwrap().success());
    wait_for_logs();

    let text = fs::read_to_string(&daily).unwrap();
    let lines: Vec<_> = text
        .lines()
        .filter_map(|line| line.split_once(" INFO test queued #").map(|(_, n)| n))
        .map(|n| n.parse::<usize>().unwrap())
        .collect();
    assert_eq!(lines, (0..writer::QUEUE_LINES).collect::<Vec<_>>());
    assert_eq!(
        text.matches(" WARN runtime dropped 3 runtime log lines (queue full)")
            .count(),
        1
    );
    log.write_at(now, "INFO", "test", "still accepting");
    wait_for_logs();
    let text = fs::read_to_string(daily).unwrap();
    assert!(text.ends_with(" INFO test still accepting\n"));
    assert_eq!(text.matches(" WARN runtime dropped ").count(), 1);
}

#[test]
fn e2_fix2_short_file_lock_contention_retries_until_written() {
    use std::sync::mpsc;
    if run_lock_test_in_child(
        "diagnostics::tests::e2_fix2_short_file_lock_contention_retries_until_written",
    ) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    log.write("INFO", "test", "initialize");
    wait_for_logs();
    let lock = OpenOptions::new()
        .write(true)
        .open(temp.path().join("logs/.writer.lock"))
        .unwrap();
    FileExt::lock_exclusive(&lock).unwrap();
    let (send, receive) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        send.send(()).unwrap();
        log.try_write(Local::now(), "INFO", "test", "retried successfully")
    });
    receive.recv_timeout(StdDuration::from_secs(2)).unwrap();
    // Deliberately model another handle retaining the lock for about 50 ms.
    std::thread::sleep(StdDuration::from_millis(50));
    FileExt::unlock(&lock).unwrap();
    let result = worker.join().unwrap();
    assert!(
        result.is_ok(),
        "short contention was not retried: {result:?}"
    );
    wait_for_logs();
    let text = fs::read_to_string(temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    )))
    .unwrap();
    assert_eq!(text.matches("retried successfully").count(), 1);
}

#[test]
fn e2_fix1_multiline_errors_and_non_frame_stack_are_omitted() {
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    let stack = format!(
        "PRIVATE_STACK\n{}",
        (0..25)
            .map(|n| format!("#{n}  frame (file:///app.dart:12:3)"))
            .collect::<Vec<_>>()
            .join("\n")
    );
    log.flutter_error("StateError", "prompt:\nPRIVATE_TEXT", &stack);
    log.flutter_error(
        "StateError",
        &format!("{}PRIVATE_LONG", "字".repeat(200)),
        "",
    );
    wait_for_logs();
    let text = fs::read_to_string(temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    )))
    .unwrap();
    for marker in ["PRIVATE_TEXT", "PRIVATE_STACK", "PRIVATE_LONG", "#20 "] {
        assert!(!text.contains(marker), "leaked {marker}");
    }
    assert!(text.contains("#0  frame"));
}

#[test]
fn e2_fix1_contended_file_lock_has_a_deadline() {
    use std::{
        sync::mpsc,
        time::{Duration as StdDuration, Instant},
    };
    if run_lock_test_in_child("diagnostics::tests::e2_fix1_contended_file_lock_has_a_deadline") {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    log.write("INFO", "test", "initialize");
    wait_for_logs();
    let lock = OpenOptions::new()
        .write(true)
        .open(temp.path().join("logs/.writer.lock"))
        .unwrap();
    FileExt::lock_exclusive(&lock).unwrap();
    let (send, receive) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let at = Instant::now();
        log.write("INFO", "test", "contended");
        send.send(at.elapsed()).unwrap();
    });
    let returned = receive.recv_timeout(StdDuration::from_millis(450));
    let business = returned.is_ok().then(|| {
        let client = crate::api::stats::StatsClient::new(
            temp.path().to_string_lossy().into(),
            Some(temp.path().to_string_lossy().into()),
        )
        .unwrap();
        client.sync_isolated()
    });
    FileExt::unlock(&lock).unwrap();
    worker.join().unwrap();
    assert!(
        returned.is_ok(),
        "logging waited for another handle indefinitely"
    );
    assert!(returned.unwrap() < StdDuration::from_millis(400));
    assert!(business.unwrap().is_ok());
}

#[test]
fn e2_fix1_tail_reader_never_exceeds_its_read_budget() {
    struct Reader {
        inner: std::io::Cursor<Vec<u8>>,
        read: usize,
    }
    impl Read for Reader {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.inner.read(buf)?;
            self.read += n;
            Ok(n)
        }
    }
    impl Seek for Reader {
        fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
            self.inner.seek(position)
        }
    }
    let text = "字".repeat(1000);
    let mut reader = Reader {
        inner: std::io::Cursor::new(text.as_bytes().to_vec()),
        read: 0,
    };
    let (tail, skipped) = read_log_tail(&mut reader, text.len() as u64, 101).unwrap();
    assert!(reader.read <= 101);
    assert!(std::str::from_utf8(&tail).is_ok());
    assert_eq!(tail.len() as u64 + skipped, text.len() as u64);
}

#[cfg(windows)]
#[test]
fn e2_fix1_home_uri_encoded_and_mixed_paths_are_private_in_export() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("PRIVATE User");
    let data = home.join("data");
    let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
    let native = home.to_string_lossy().to_string();
    let mixed: String = native
        .chars()
        .enumerate()
        .map(|(i, c)| if c == '\\' && i % 2 == 0 { '/' } else { c })
        .collect();
    let uri = reqwest::Url::from_directory_path(&home)
        .unwrap()
        .to_string();
    let forms = [
        format!("{mixed}\\trace"),
        format!("{uri}trace"),
        format!("{}\\trace", native.replace('\\', "\\\\")),
        format!("{}\\trace", native.to_ascii_lowercase().replace(' ', "%20")),
    ];
    for form in &forms {
        let redacted = redact_home(form, Some(&home));
        assert!(
            !redacted.to_ascii_lowercase().contains("private"),
            "{redacted}"
        );
    }
    wait_for_logs();
    fs::write(
        data.join(format!(
            "logs/token-lens-{}.log",
            Local::now().format("%Y-%m-%d")
        )),
        forms.join("\n"),
    )
    .unwrap();
    let export = RuntimeLog::new(&data, Some(&home))
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    assert!(!fs::read_to_string(export)
        .unwrap()
        .to_ascii_lowercase()
        .contains("private"));
}

#[test]
fn e2_fix1_conflict_id_delimiter_and_unknown_paths_cannot_leak() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    let a = logs.join("a.jsonl");
    let b = logs.join("b.jsonl");
    fs::write(&a, "").unwrap();
    fs::write(&b, "").unwrap();
    let outside = temp.path().join("PRIVATE_OUTSIDE.jsonl");
    fs::write(&outside, "").unwrap();
    let data = temp.path().join("data");
    let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
    let id = ledger.begin_run().unwrap();
    ledger.finish_run(id, "ok", &serde_json::json!({"attempted":0,"inserted":0,"updated":0,"unchanged":0,"rejected":0,"anomalies":[format!("cross_file_conflict: id — {} — {} 的用量与 {} 不同，按后者计", temp.path().join("PRIVATE_ID").display(), a.display(), b.display()),format!("cross_file_conflict: id — {} 的用量与 {} 不同，按后者计", outside.display(), b.display())]})).unwrap();
    let path = RuntimeLog::new(&data, Some(&home))
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let text = fs::read_to_string(path).unwrap();
    assert!(!text.contains("PRIVATE_ID"));
    assert!(!text.contains("PRIVATE_OUTSIDE"));
    assert!(text.contains("conflicting-file="));
}

#[test]
fn e2_fix1_export_only_reads_budgeted_newest_utf8_tail() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let ledger = Ledger::open(&temp.path().join("ledger.db"), Clock::System).unwrap();
    let path = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    wait_for_logs();
    let mut file = fs::File::create(path).unwrap();
    file.write_all(&[0xff]).unwrap(); // An obsolete, unreadable prefix must never enter the buffer.
    let block = "字".repeat(4096);
    for _ in 0..2048 {
        file.write_all(block.as_bytes()).unwrap();
    }
    file.write_all(b"newest-end\n").unwrap();
    drop(file);
    let export = RuntimeLog::new(temp.path(), Some(&home))
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let text = fs::read_to_string(export).unwrap();
    assert!(text.starts_with("[截断："));
    assert!(text.len() <= EXPORT_LIMIT);
    assert!(text.ends_with("newest-end\n"));
}

#[test]
fn e2_fix1_cap_includes_marker_bytes_and_keeps_utf8_valid() {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir_all(temp.path().join("logs")).unwrap();
    let path = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    fs::write(&path, format!("{}aa", "字".repeat(LOG_LIMIT as usize / 3))).unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    let result = log.try_write(Local::now(), "INFO", "test", "over cap");
    assert!(result.is_ok(), "{result:?}");
    log.write("INFO", "test", "after cap");
    wait_for_logs();
    assert!(fs::metadata(&path).unwrap().len() <= LOG_LIMIT);
    let text = fs::read_to_string(path).unwrap();
    assert_eq!(text.matches(LIMIT_MARK).count(), 1);
    assert!(!text.contains("after cap"));
}

#[cfg(windows)]
#[test]
fn e2_windows_os_version_and_mixed_path_redaction() {
    assert!(!os_version().contains('\u{fffd}'));
    assert!(os_version().contains("Microsoft Windows"));
    let home = Path::new("C:\\Users\\private/AppData/home");
    assert_eq!(
        redact_home("C:\\Users\\private\\AppData\\home\\app.dart", Some(home)),
        "~\\app.dart"
    );
}

#[test]
fn e2_cap_text_in_a_business_message_does_not_stop_logging() {
    let temp = tempfile::tempdir().unwrap();
    let log = RuntimeLog::new(temp.path(), None);
    log.write("ERROR", "flutter", "已达上限");
    log.write("INFO", "test", "still-writing");
    wait_for_logs();
    let file = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    assert!(fs::read_to_string(file).unwrap().contains("still-writing"));
}

#[test]
fn e2_sync_cancellation_records_terminal_event() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    fs::write(logs.join("empty.jsonl"), "").unwrap();
    let result = crate::stats::ingest::sync(
        temp.path(),
        &home,
        &Environment::default(),
        Clock::System,
        &crate::stats::jscompat::LocalZone::System,
        &std::sync::atomic::AtomicBool::new(true),
    );
    assert_eq!(result.unwrap_err().0, "cancelled");
    wait_for_logs();
    let file = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    assert!(fs::read_to_string(file).unwrap().contains("cancelled"));
}

#[test]
fn e2_flutter_error_excludes_sensitive_fields_and_redacts_path_forms() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("private-home");
    let log = RuntimeLog::new(temp.path(), Some(&home));
    let marker = "E2_SECRET_ERROR_CONTENT";
    log.flutter_error("FormatException", &format!("parse failed prompt={marker}\nAuthorization: Bearer {marker}\napi_key={marker}\ntool arguments={marker}"), &format!("#0 {}", home.join("app.dart").display()));
    wait_for_logs();
    let file = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    let text = fs::read_to_string(file).unwrap();
    assert!(!text.contains(marker));
    assert!(!text.contains(home.to_str().unwrap()));
    for form in [
        home.to_string_lossy().to_string(),
        home.to_string_lossy().replace('\\', "/"),
        home.to_string_lossy().replace('\\', "\\\\"),
    ] {
        assert_eq!(redact_home(&format!("{form}/test"), Some(&home)), "~/test");
    }
}

#[test]
fn e2_daily_retention_cap_and_concurrency() {
    if run_lock_test_in_child("diagnostics::tests::e2_daily_retention_cap_and_concurrency") {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let log = Arc::new(RuntimeLog::new(temp.path(), None));
    let now = Local::now();
    log.write_at(now - Duration::days(8), "INFO", "test", "expired");
    log.write_at(now - Duration::days(6), "INFO", "test", "retained");
    log.write_at(now, "INFO", "test", "today");
    let name = |date: chrono::DateTime<Local>| {
        temp.path()
            .join(format!("logs/token-lens-{}.log", date.format("%Y-%m-%d")))
    };
    wait_for_logs();
    assert!(!name(now - Duration::days(8)).exists());
    assert!(name(now - Duration::days(6)).exists());
    let workers: Vec<_> = (0..8)
        .map(|worker| {
            let log = log.clone();
            std::thread::spawn(move || {
                for line in 0..100 {
                    log.write("INFO", "parallel", &format!("worker={worker} line={line}"));
                }
            })
        })
        .collect();
    for worker in workers {
        worker.join().unwrap();
    }
    wait_for_logs();
    let text = fs::read_to_string(name(now)).unwrap();
    assert_eq!(
        text.lines()
            .filter(|line| line.contains(" INFO parallel worker="))
            .count(),
        800
    );
    assert!(text.lines().all(|line| line.matches(" INFO ").count() == 1));
    fs::write(name(now), "a".repeat(5 * 1024 * 1024)).unwrap();
    log.write("WARN", "test", "must-not-append");
    log.write("ERROR", "test", "must-not-append-either");
    wait_for_logs();
    let text = fs::read_to_string(name(now)).unwrap();
    assert_eq!(text.matches("已达上限").count(), 1);
    assert!(!text.contains("must-not-append"));
    fs::write(name(now), "a".repeat(5 * 1024 * 1024 - 512)).unwrap();
    log.write("INFO", "test", &"x".repeat(1024));
    log.write("INFO", "test", "small-after-cap");
    wait_for_logs();
    let text = fs::read_to_string(name(now)).unwrap();
    assert_eq!(text.matches("已达上限").count(), 1);
    assert!(!text.contains("small-after-cap"));
}

#[test]
fn e2_unwritable_logs_do_not_fail_business() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    fs::write(temp.path().join("logs"), "not a directory").unwrap();
    let client = crate::api::stats::StatsClient::new(
        temp.path().to_string_lossy().into(),
        Some(home.to_string_lossy().into()),
    )
    .unwrap();
    assert!(client.sync_isolated().is_ok());
    assert_eq!(client.health().unwrap().schema_version, 7);
}

#[test]
fn e2_export_all_sections_ten_runs_all_anomalies_and_privacy() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("private-home");
    let data = home.join("data");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    let marker = "E2_PRIVATE_BODY_PROMPT_TOOL_93A7";
    // Conflicting copies create an anomaly whose record key also contains the marker.
    for (name, tokens) in [("a", 10), ("b", 20)] {
        let row = serde_json::json!({"sessionId":"s","timestamp":"2026-01-15T01:00:00Z","prompt":marker,"message":{"id":marker,"model":"unknown","content":[{"type":"text","text":marker},{"type":"tool_use","input":{"command":marker}}],"usage":{"input_tokens":tokens}}});
        fs::write(logs.join(format!("{name}.jsonl")), format!("{row}\n")).unwrap();
    }
    let broken = home.join(".codex/sessions/rollout-broken.jsonl.zst");
    fs::create_dir_all(broken.parent().unwrap()).unwrap();
    fs::write(broken, marker).unwrap();
    let client = crate::api::stats::StatsClient::new(
        data.to_string_lossy().into(),
        Some(home.to_string_lossy().into()),
    )
    .unwrap();
    let result = client.sync_isolated().unwrap();
    assert!(!result.anomalies.is_empty());
    assert!(result.counts.read_failed > 0);
    // A failed run and arbitrary pre-existing note must never copy parser data into diagnostics.
    let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
    for _ in 0..12 {
        let id = ledger.begin_run().unwrap();
        ledger.finish_run(id, "ok", &serde_json::json!({"attempted":1,"inserted":1,"updated":0,"unchanged":0,"rejected":0,"counts":{"bad_lines":2},"anomalies":[format!("rejected: {marker} — kind 非法：{marker}"),"vanished: synthetic — 2 条记录不再出现，保留原值","bad note", "fourth", "fifth", "sixth"]})).unwrap();
    }
    let id = ledger.begin_run().unwrap();
    ledger.fail_run(id, marker).unwrap();
    let logger = RuntimeLog::new(&data, Some(&home));
    logger.write(
        "INFO",
        "test",
        &format!("path={}", home.join("folder").display()),
    );
    let path = logger
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let text = fs::read_to_string(&path).unwrap();
    for heading in ["[应用]", "[最近同步]", "[来源]", "[运行日志]"] {
        assert!(text.contains(heading), "missing {heading}");
    }
    assert_eq!(text.matches("run id=").count(), 10);
    assert_eq!(text.matches("anomaly ").count(), 9 * 6 + 1);
    assert!(text.contains("files=2"));
    assert!(text.contains(".claude"));
    assert!(text.contains("schema=6"));
    assert!(text.contains("~/folder") || text.contains("~\\folder"));
    let filename = path.file_name().unwrap().to_str().unwrap();
    assert!(chrono::NaiveDateTime::parse_from_str(
        filename,
        "token-lens-diagnostics-%Y%m%d-%H%M%S.txt"
    )
    .is_ok());
    assert!(!text.contains(marker));
    assert!(!text.contains(home.to_str().unwrap()));
    for file in fs::read_dir(data.join("logs"))
        .unwrap()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|s| s == "log"))
    {
        let body = fs::read_to_string(file.path()).unwrap();
        assert!(!body.contains(marker));
        assert!(!body.contains(home.to_str().unwrap()));
    }
    // The test runner may request a real sample, always from this synthetic ledger.
    if let Some(sample) = std::env::var_os("TOKEN_LENS_E2_SAMPLE") {
        fs::copy(path, sample).unwrap();
    }
}

#[test]
fn e2_export_truncates_latest_logs_and_marks_exact_bytes() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let ledger = Ledger::open(&temp.path().join("ledger.db"), Clock::System).unwrap();
    let log = RuntimeLog::new(temp.path(), Some(&home));
    let today = Local::now();
    wait_for_logs();
    fs::create_dir_all(temp.path().join("logs")).unwrap();
    for offset in [1, 0] {
        fs::write(
            temp.path().join(format!(
                "logs/token-lens-{}.log",
                (today - Duration::days(offset)).format("%Y-%m-%d")
            )),
            format!(
                "old-{offset}\n{}\nend-{offset}\n",
                "字".repeat(2 * 1024 * 1024)
            ),
        )
        .unwrap();
    }
    let path = log
        .export(
            &ledger,
            &temp.path().join("exports"),
            &home,
            &Environment::default(),
        )
        .unwrap();
    let text = fs::read_to_string(path).unwrap();
    assert!(text.starts_with("[截断："));
    for heading in ["[应用]", "[最近同步]", "[来源]", "[运行日志]"] {
        assert!(text.contains(heading));
    }
    assert!(text.len() <= 8 * 1024 * 1024);
    assert!(!text.contains("old-1"));
    assert!(text.ends_with("end-0\n"));
}

#[test]
fn f1_cancelled_sync_is_one_info_and_other_errors_stay_errors() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let result = crate::stats::ingest::sync(
        temp.path(),
        &home,
        &Environment::default(),
        Clock::System,
        &crate::stats::jscompat::LocalZone::System,
        &std::sync::atomic::AtomicBool::new(true),
    );
    let log = RuntimeLog::new(temp.path(), Some(&home));
    let result: Result<(), String> = result.map(|_| ()).map_err(|error| error.to_string());
    assert_eq!(log.ffi("sync", result).unwrap_err(), "cancelled");
    wait_for_logs();
    let file = temp.path().join(format!(
        "logs/token-lens-{}.log",
        Local::now().format("%Y-%m-%d")
    ));
    let text = fs::read_to_string(&file).unwrap();
    let cancelled: Vec<_> = text
        .lines()
        .filter(|line| line.contains("cancelled"))
        .collect();
    assert_eq!(cancelled.len(), 1, "{text}");
    assert!(cancelled[0].contains("INFO"), "{text}");
    log.ffi::<()>("sync", Err("closed".into())).unwrap_err();
    wait_for_logs();
    let text = fs::read_to_string(file).unwrap();
    assert!(
        text.lines().any(|line| line.contains("ERROR")
            && line.contains("ffi")
            && line.contains("sync: closed")),
        "{text}"
    );
}
