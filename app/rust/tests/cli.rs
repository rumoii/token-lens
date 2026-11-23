use rusqlite::Connection;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::Path,
    process::{Command, Output},
};

fn cli(data: Option<&Path>, home: Option<&Path>, args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_token-lens-cli"));
    command
        .env_remove("TOKEN_LENS_PREVIEW_DATA_DIR")
        .env_remove("TOKEN_LENS_PREVIEW_HOME")
        .env("TOKEN_LENS_CLI_TEST_NOW", "2026-03-31T16:00:00Z");
    if let Some(data) = data {
        command.arg("--data-dir").arg(data);
    }
    if let Some(home) = home {
        command.env("TOKEN_LENS_PREVIEW_HOME", home);
    }
    command.args(args).output().unwrap()
}

fn success(out: Output, command: &str) -> Value {
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stderr.is_empty());
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["format_version"], 1);
    assert_eq!(v["command"], command);
    assert!(v["generated_at"].is_string());
    assert!(v["data"].is_object());
    assert!(v["query"].is_object());
    assert!(v["freshness"].is_object());
    v
}

fn error(out: Output, status: i32, code: &str) {
    assert_eq!(out.status.code(), Some(status));
    assert!(out.stdout.is_empty());
    let v: Value = serde_json::from_slice(&out.stderr).unwrap();
    assert_eq!(v["format_version"], 1);
    assert_eq!(v["error"]["code"], code);
    assert!(v["error"]["message"].is_string());
}

#[test]
fn cli_sync_preserves_ffi_manual_and_downloaded_prices() {
    use rust_lib_token_lens::api::stats::StatsClient;

    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("data");
    let home = temp.path().join("home");
    let logs = home.join(".claude/projects/demo");
    fs::create_dir_all(&logs).unwrap();
    let models = ["manual-demo", "online-demo", "claude-opus-4-6"];
    let records = models.iter().enumerate().map(|(i, model)| {
        json!({"sessionId":"test","timestamp":"2026-03-30T12:00:00Z",
            "message":{"id":format!("test-{i}"),"model":model,"usage":{"input_tokens":101+i,"output_tokens":17}}})
    }).map(|row| row.to_string()).collect::<Vec<_>>().join("\n");
    fs::write(logs.join("test.jsonl"), format!("{records}\n")).unwrap();
    let client = StatsClient::new(
        data.to_string_lossy().into_owned(),
        Some(home.to_string_lossy().into_owned()),
    )
    .unwrap();
    client.sync_triggered("pricing".into()).unwrap();
    let costs = || {
        let db = Connection::open(data.join("ledger.db")).unwrap();
        models.map(|model| {
            db.query_row(
                "SELECT cost_micros FROM usage_records WHERE model=? AND active=1",
                [model],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap()
        })
    };
    let before = costs();
    assert_eq!(&before[..2], &[None, None]);
    client
        .save_manual_price(
            json!({"model":"manual-demo","currency":"CNY","rate":7,"input":7,"output":14})
                .to_string(),
        )
        .unwrap();
    assert_eq!(client.sync_triggered("pricing".into()).unwrap().repriced, 3);
    let manual = costs();
    assert_eq!(manual, [Some(135), None, before[2]]);

    let mut next: Value =
        serde_json::from_str(include_str!("../src/stats/pricing-catalog.json")).unwrap();
    let mut entry = next["entries"][0].clone();
    entry["id"] = json!("online-demo");
    entry["aliases"] = json!([]);
    entry["perMTok"]["input"] = json!(1);
    entry["perMTok"]["output"] = json!(2);
    next["entries"].as_array_mut().unwrap().push(entry);
    next["publishedAt"] = json!("2026-11-23");
    let installed = client.install_price_catalog(next.to_string()).unwrap();
    assert_eq!(installed.kind, "installed");
    assert_eq!(installed.newly_priced, Some(1));
    assert_eq!(client.sync_triggered("pricing".into()).unwrap().repriced, 3);
    let priced = costs();
    assert_eq!(priced, [Some(135), Some(136), before[2]]);
    let snapshot = client.pricing().unwrap();
    fs::write(
        data.join("ui-preferences.json"),
        r#"{"rates":{"USD":1,"CNY":12}}"#,
    )
    .unwrap();

    let status = success(cli(Some(&data), Some(&home), &["status"]), "status");
    assert_eq!(status["data"]["price_version"], snapshot.price_version);
    let sync = success(cli(Some(&data), Some(&home), &["sync"]), "sync");
    assert_eq!(sync["data"]["skipped_files"], 1);
    assert_eq!(sync["data"]["attempted"], 0);
    assert_eq!(sync["data"]["repriced"], 0);
    assert_eq!(costs(), priced);

    client.remove_manual_price("manual-demo".into()).unwrap();
    client.sync_triggered("pricing".into()).unwrap();
    assert_eq!(costs(), [None, Some(136), before[2]]);
    client.remove_price_catalog().unwrap();
    client.sync_triggered("pricing".into()).unwrap();
    assert_eq!(costs(), before);
}

#[test]
fn normal_cli_exit_flushes_runtime_logs() {
    use fs2::FileExt;
    use std::{
        io::{BufRead, BufReader},
        process::Stdio,
    };

    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let logs = data.join("logs");
    fs::create_dir(&home).unwrap();
    fs::create_dir_all(&logs).unwrap();
    let lock = fs::File::create(logs.join(".writer.lock")).unwrap();
    FileExt::lock_exclusive(&lock).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_token-lens-cli"))
        .arg("--data-dir")
        .arg(&data)
        .arg("sync")
        .env("TOKEN_LENS_PREVIEW_HOME", &home)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut receipt = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut receipt)
        .unwrap();
    FileExt::unlock(&lock).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        serde_json::from_str::<Value>(&receipt).unwrap()["command"],
        "sync"
    );
    let logs = fs::read_dir(logs)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
        .map(|path| fs::read_to_string(path).unwrap())
        .collect::<Vec<_>>()
        .join("");
    assert!(logs.contains("end durationMs="), "{logs}");
    assert!(logs.contains("phases "), "{logs}");
}

#[test]
fn shortcut_summary_compares_full_calendar_months() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let logs = home.join(".claude/projects/demo");
    fs::create_dir_all(&logs).unwrap();
    for (session, day, tokens) in [("prior", "2026-01-15", 5), ("current", "2026-02-15", 20)] {
        let row = json!({
            "sessionId": session, "timestamp": format!("{day}T12:00:00Z"),
            "message": {"id": session, "model": "claude-opus-4-6", "usage": {"input_tokens": tokens}}
        });
        fs::write(logs.join(format!("{session}.jsonl")), format!("{row}\n")).unwrap();
    }
    // Mid-month UTC keeps the target months the same in every local time zone.
    let out = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_token-lens-cli"))
            .arg("--data-dir")
            .arg(&data)
            .env("TOKEN_LENS_PREVIEW_HOME", &home)
            .env("TOKEN_LENS_CLI_TEST_NOW", "2026-03-15T12:00:00Z")
            .args(args)
            .output()
            .unwrap()
    };
    assert_eq!(success(out(&["sync"]), "sync")["data"]["inserted"], 2);
    let result = success(
        out(&["summary", "--period", "lastMonth", "--compare"]),
        "summary",
    );
    assert_eq!(result["query"]["period"], "lastMonth");
    assert_eq!(result["query"]["from"], "2026-02-01");
    assert_eq!(result["query"]["to"], "2026-02-28");
    assert_eq!(result["data"]["current"]["total_tokens"], 20);
    let previous = &result["data"]["previous"];
    assert_eq!(previous["query"]["period"], "lastMonth");
    assert_eq!(previous["query"]["from"], "2026-01-01");
    assert_eq!(previous["query"]["to"], "2026-01-31");
    assert_eq!(previous["totals"]["total_tokens"], 5);
}

#[test]
fn usage_and_read_only_open_have_distinct_errors() {
    let temp = tempfile::tempdir().unwrap();
    let data = temp.path().join("absent");
    error(cli(Some(&data), None, &["status"]), 2, "no_ledger");
    assert!(!data.exists());
    error(
        cli(Some(&data), None, &["breakdown", "--by", "invalid"]),
        1,
        "usage",
    );
    if cfg!(debug_assertions) {
        error(cli(None, None, &["status"]), 1, "usage");
        error(cli(Some(&data), None, &["sync"]), 1, "usage");
    }
    fs::create_dir(&data).unwrap();
    let path = data.join("ledger.db");
    let db = Connection::open(&path).unwrap();
    db.execute_batch("PRAGMA user_version=6").unwrap();
    let before = Sha256::digest(fs::read(&path).unwrap());
    error(cli(Some(&data), None, &["status"]), 2, "ledger_version");
    assert_eq!(before, Sha256::digest(fs::read(&path).unwrap()));
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        6
    );
    let lock = Connection::open(data.join("sync-lock.db")).unwrap();
    lock.execute_batch("BEGIN IMMEDIATE").unwrap();
    error(
        cli(Some(&data), Some(temp.path()), &["sync"]),
        3,
        "sync_busy",
    );
    assert_eq!(before, Sha256::digest(fs::read(&path).unwrap()));
}

#[test]
fn reads_synthetic_usage_without_changing_the_main_database() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    let rows = [
        (
            "a",
            "one",
            "claude-opus-4-6",
            "2026-03-29",
            "/first/shared",
            20,
        ),
        (
            "b",
            "one",
            "claude-opus-4-6",
            "2026-03-30",
            "/first/shared",
            15,
        ),
        (
            "c",
            "two",
            "claude-opus-4-6",
            "2026-03-30",
            "/other/shared",
            10,
        ),
        (
            "d",
            "unknown",
            "unpriced-synthetic",
            "2026-03-30",
            "/other/shared",
            900,
        ),
        ("e", "prior", "claude-opus-4-6", "2026-02-28", "=formula", 5),
        (
            "f",
            "four",
            "claude-opus-4-6",
            "2026-03-30",
            "/other/shared",
            10,
        ),
    ];
    let mut fixtures = std::collections::BTreeMap::<_, Vec<String>>::new();
    for (id, session, model, day, project, tokens) in rows {
        fixtures.entry(session).or_default().push(
            json!({
                "cwd": project, "sessionId": session, "timestamp": format!("{day}T12:00:00Z"),
                "message": {"id": id, "model": model, "usage": {"input_tokens": tokens}}
            })
            .to_string(),
        );
    }
    for (session, lines) in fixtures {
        fs::write(
            logs.join(format!("synthetic-{session}.jsonl")),
            lines.join("\n"),
        )
        .unwrap();
    }
    let read = |args: &[&str], name| success(cli(Some(&data), None, args), name);
    let sync = success(cli(Some(&data), Some(&home), &["sync"]), "sync");
    assert_eq!(sync["data"]["inserted"], 6);
    let path = data.join("ledger.db");
    // Hold a writer with committed WAL data and no checkpoint.
    let writer = Connection::open(&path).unwrap();
    writer
        .execute_batch("PRAGMA wal_autocheckpoint=0; UPDATE usage_records SET input_tokens=7 WHERE session_id='prior'; BEGIN IMMEDIATE;")
        .unwrap();
    let before = Sha256::digest(fs::read(&path).unwrap());
    let status = read(&["status"], "status");
    assert_eq!(status["data"]["ledger_version"], 7);
    assert_eq!(status["data"]["last_sync"]["trigger"], "cli");
    assert_eq!(status["data"]["tools_with_usage"], 1);
    assert_eq!(status["data"]["last_sync"]["counts"]["inserted"], 6);
    let summary = read(&["summary", "--period", "all"], "summary");
    assert_eq!(summary["data"]["session_count"], 5);
    assert_eq!(summary["data"]["input_tokens"], 962);
    assert_eq!(summary["data"]["output_tokens"], Value::Null);
    let compare = read(&["summary", "--compare"], "summary");
    if cfg!(debug_assertions) {
        assert_eq!(compare["query"]["from"], "2026-03-01");
        assert_eq!(compare["data"]["previous"]["query"]["to"], "2026-02-28");
    }
    for by in ["tool", "model", "project", "day", "hour", "month"] {
        let result = read(&["breakdown", "--by", by, "--period", "all"], "breakdown");
        let groups = result["data"]["rows"].as_array().unwrap();
        for key in [
            "total_tokens",
            "input_tokens",
            "cost_micros",
            "record_count",
        ] {
            let sum: i64 = groups.iter().filter_map(|group| group[key].as_i64()).sum();
            assert_eq!(Some(sum), summary["data"][key].as_i64(), "{by} {key}");
        }
        if by == "day" {
            assert_eq!(
                groups
                    .iter()
                    .filter_map(|g| g["session_count"].as_i64())
                    .sum::<i64>(),
                6
            );
        }
    }
    let projects = read(
        &["breakdown", "--by", "project", "--period", "all"],
        "breakdown",
    );
    assert!(projects["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .any(|g| g["key"] == "first / shared"));
    assert!(!projects.to_string().contains("project_path"));
    let paths = read(
        &[
            "breakdown",
            "--by",
            "project",
            "--period",
            "all",
            "--project-paths",
        ],
        "breakdown",
    );
    assert!(paths.to_string().contains("/first/shared"));
    let filtered = read(
        &["summary", "--period", "all", "--project", "shared"],
        "summary",
    );
    assert_eq!(filtered["data"]["record_count"], 5);

    let mut cursor: Option<String> = None;
    let mut ids = Vec::new();
    loop {
        let mut args = vec![
            "sessions", "--sort", "cost", "--limit", "2", "--period", "all",
        ];
        if let Some(ref cursor) = cursor {
            args.extend(["--cursor", cursor]);
        }
        let value = read(&args, "sessions");
        for row in value["data"]["items"].as_array().unwrap() {
            ids.push(row["session_id"].as_str().unwrap().to_owned());
        }
        cursor = value["data"]["next_cursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            break;
        }
        assert!(ids.len() <= 5);
    }
    assert_eq!(ids, ["one", "four", "two", "prior", "unknown"]);
    let session = read(&["session", "--tool", "claude", "--id", "one"], "session");
    assert_eq!(session["data"]["total_tokens"], 35);
    assert!(session["data"]["models"].is_array());
    let sources = read(&["sources"], "sources");
    assert!(sources["data"]["sources"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["tool"] == "claude" && s["record_count"] == 6 && s["last_sync_status"] == "ok"));
    for out in [
        status, summary, compare, projects, paths, session, sources, sync,
    ] {
        let text = out.to_string();
        for key in [
            "record_key",
            "source_file",
            "content_hash",
            "synthetic-prior.jsonl",
            "data_dir",
        ] {
            assert!(!text.contains(key), "{key} in {text}");
        }
        assert!(!text.contains(&temp.path().to_string_lossy().replace('\\', "\\\\")));
    }
    assert_eq!(before, Sha256::digest(fs::read(path).unwrap()));
}

#[test]
fn version_and_help_are_json_without_a_ledger() {
    assert_eq!(
        success(cli(None, None, &["--version"]), "version")["data"]["version"],
        env!("CARGO_PKG_VERSION")
    );
    assert!(success(cli(None, None, &["--help"]), "help")["data"]["usage"].is_string());
}

#[test]
fn shared_export_bytes_and_collision_handling() {
    use rust_lib_token_lens::api::stats::{StatsClient, StatsFilter, StatsUsageExport};
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let data = temp.path().join("data");
    let logs = home.join(".claude/projects");
    fs::create_dir_all(&logs).unwrap();
    for (id, name) in ["=x", "+x", "-x", "@x", "\tx", "\rx", "comma,\"name\""]
        .into_iter()
        .enumerate()
    {
        let line = json!({
            "cwd": format!("/synthetic/{name}"),"timestamp":"2026-03-31T12:00:00Z",
            "sessionId":format!("synthetic-{id}"),
            "message":{"id":format!("r-{id}"),"model":"claude-opus-4-6","usage":{"input_tokens":10}}
        });
        fs::write(logs.join(format!("exports-{id}.jsonl")), line.to_string()).unwrap();
    }
    success(cli(Some(&data), Some(&home), &["sync"]), "sync");
    let clock = chrono::DateTime::parse_from_rfc3339("2026-03-31T16:00:00Z").unwrap();
    let client = StatsClient::new_with_fixed_clock(
        data.to_str().unwrap().into(),
        Some(home.to_str().unwrap().into()),
        clock.timestamp_millis(),
    )
    .unwrap();
    let destination = temp.path().join("out");
    let offset = clock
        .with_timezone(&chrono::Local)
        .offset()
        .local_minus_utc()
        / 60;
    let export = |format: &str| {
        client
            .export_usage(
                StatsUsageExport {
                    by: "project".into(),
                    period: "all".into(),
                    filter: StatsFilter::default(),
                    format: format.into(),
                    project_paths: false,
                    directory: destination.to_str().unwrap().into(),
                },
                offset,
            )
            .unwrap()
    };
    let json_path = export("json");
    let expected = cli(
        Some(&data),
        None,
        &["breakdown", "--by", "project", "--period", "all"],
    );
    assert!(expected.status.success());
    if cfg!(debug_assertions) {
        assert_eq!(fs::read(&json_path).unwrap(), expected.stdout);
    }
    let json_path_two = export("json");
    assert!(json_path_two.ends_with("token-lens-project-all-all-2.json"));
    assert_eq!(
        fs::read(json_path).unwrap(),
        fs::read(json_path_two).unwrap()
    );
    let csv = fs::read(export("csv")).unwrap();
    assert!(csv.starts_with(&[0xef, 0xbb, 0xbf]));
    let csv = std::str::from_utf8(&csv[3..]).unwrap();
    assert!(csv.starts_with("key,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens,record_count,request_count,session_count,cost_usd,cost_micros,currency,unpriced_records\r\n"));
    for prefix in ["'=", "'+", "'-", "'@", "'\t", "'\r"] {
        assert!(csv.contains(prefix), "{prefix:?} missing from {csv:?}");
    }
    assert!(csv.contains("\"comma,\"\"name\"\"\""));
}

fn synthetic_pricing_profile() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let logs = home.join(".opencode");
    fs::create_dir_all(&logs).unwrap();
    let db = Connection::open(logs.join("opencode.db")).unwrap();
    db.execute_batch(
        "CREATE TABLE session(id TEXT, directory TEXT);
         CREATE TABLE message(id TEXT, session_id TEXT, time_updated INTEGER, time_created INTEGER, data TEXT);",
    )
    .unwrap();
    for (session, project, day, model, provider) in [
        ("jan", "mixed", "2026-01-15", "claude-opus-4-6", "remote"),
        ("feb", "mixed", "2026-02-15", "unpriced-synthetic", "remote"),
        ("mar", "mixed", "2026-03-15", "claude-opus-4-6", "remote"),
        ("local", "local", "2026-03-15", "local-synthetic", "OLLaMa"),
        (
            "unknown",
            "unpriced",
            "2026-02-15",
            "unpriced-synthetic",
            "remote",
        ),
    ] {
        let time = chrono::DateTime::parse_from_rfc3339(&format!("{day}T12:00:00Z"))
            .unwrap()
            .timestamp_millis();
        let message = json!({
            "role": "assistant", "modelID": model, "providerID": provider,
            "tokens": {"input": 100}
        });
        db.execute(
            "INSERT INTO session VALUES (?1,?2)",
            (session, format!("/demo/{project}")),
        )
        .unwrap();
        db.execute(
            "INSERT INTO message VALUES (?1,?1,?2,?2,?3)",
            (session, time, message.to_string()),
        )
        .unwrap();
    }
    drop(db);
    let data = temp.path().join("data");
    let sync = success(cli(Some(&data), Some(&home), &["sync"]), "sync");
    assert_eq!(sync["data"]["inserted"], 5);
    temp
}

fn cost_fields(row: &Value) -> [&Value; 2] {
    ["cost_usd", "cost_micros"].map(|field| row.get(field).unwrap())
}

#[test]
fn fully_unpriced_cli_groups_are_distinct_from_other_totals() {
    let temp = synthetic_pricing_profile();
    let data = temp.path().join("data");
    let grouped = success(
        cli(
            Some(&data),
            None,
            &["breakdown", "--by", "project", "--period", "all"],
        ),
        "breakdown",
    );
    let group = |key: &str| {
        grouped["data"]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["key"] == key)
            .unwrap()
    };
    let mixed = group("mixed");
    assert_eq!(mixed["record_count"], 3);
    assert_eq!(mixed["unpriced_records"], 1);
    assert_eq!(cost_fields(mixed), [&json!("0.001000"), &json!(1000)]);
    let local = group("local");
    assert_eq!(local["record_count"], 1);
    assert_eq!(local["unpriced_records"], 0);
    assert_eq!(cost_fields(local), [&json!("0.000000"), &json!(0)]);

    let empty = success(
        cli(
            Some(&data),
            None,
            &["summary", "--period", "all", "--model", "missing-synthetic"],
        ),
        "summary",
    );
    assert_eq!(empty["data"]["record_count"], 0);
    assert_eq!(cost_fields(&empty["data"]), [&json!("0.000000"), &json!(0)]);

    let unknown = group("unpriced");
    assert_eq!(unknown["record_count"], 1);
    assert_eq!(unknown["unpriced_records"], 1);
    assert_eq!(cost_fields(unknown), [&Value::Null, &Value::Null]);
}

#[test]
fn fully_unpriced_cli_comparison_has_unknown_delta_on_either_side() {
    let temp = synthetic_pricing_profile();
    let data = temp.path().join("data");
    let comparison = |from: &str, to: &str| {
        success(
            cli(
                Some(&data),
                None,
                &[
                    "summary",
                    "--compare",
                    "--project",
                    "mixed",
                    "--from",
                    from,
                    "--to",
                    to,
                ],
            ),
            "summary",
        )
    };
    let feb = comparison("2026-02-01", "2026-02-28");
    let mar = comparison("2026-03-01", "2026-03-31");
    assert_eq!(
        cost_fields(&feb["data"]["previous"]["totals"]),
        [&json!("0.000500"), &json!(500)]
    );
    assert_eq!(
        cost_fields(&mar["data"]["current"]),
        [&json!("0.000500"), &json!(500)]
    );
    assert_eq!(feb["data"]["current"]["unpriced_records"], 1);
    assert_eq!(mar["data"]["previous"]["totals"]["unpriced_records"], 1);
    assert_eq!(
        [
            cost_fields(&feb["data"]["current"]),
            cost_fields(&feb["data"]["delta"]),
            cost_fields(&mar["data"]["previous"]["totals"]),
            cost_fields(&mar["data"]["delta"]),
        ],
        [[&Value::Null, &Value::Null]; 4]
    );
}

#[test]
fn fully_unpriced_detail_export_uses_null_json_and_empty_csv_amounts() {
    use rust_lib_token_lens::api::stats::{StatsClient, StatsFilter, StatsUsageExport};

    let temp = synthetic_pricing_profile();
    let client = StatsClient::new(
        temp.path().join("data").to_string_lossy().into_owned(),
        Some(temp.path().join("home").to_string_lossy().into_owned()),
    )
    .unwrap();
    let export = |format: &str| {
        let path = client
            .export_usage(
                StatsUsageExport {
                    by: "project".into(),
                    period: "all".into(),
                    filter: StatsFilter::default(),
                    format: format.into(),
                    project_paths: false,
                    directory: temp.path().join("out").to_string_lossy().into_owned(),
                },
                0,
            )
            .unwrap();
        fs::read_to_string(path).unwrap()
    };
    let doc: Value = serde_json::from_str(&export("json")).unwrap();
    let unknown = doc["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["key"] == "unpriced")
        .unwrap();
    let csv = export("csv");
    let mut lines = csv.lines();
    let columns: Vec<_> = lines.next().unwrap().split(',').collect();
    let row: Vec<_> = lines
        .find(|line| line.starts_with("unpriced,"))
        .unwrap()
        .split(',')
        .collect();
    assert_eq!(row.len(), columns.len());
    let csv_costs = ["cost_usd", "cost_micros"]
        .map(|column| row[columns.iter().position(|&name| name == column).unwrap()]);
    assert_eq!(
        (cost_fields(unknown), csv_costs),
        ([&Value::Null, &Value::Null], ["", ""])
    );
}
