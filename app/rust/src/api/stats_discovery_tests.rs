use super::*;
use std::{fs, path::Path};

const CLAUDE: &str = r#"{"sessionId":"s0a","timestamp":"2026-01-15T12:00:00Z","message":{"id":"s0a","usage":{"input_tokens":10}}}"#;
const GEMINI: &str =
    r#"{"id":"s0a","timestamp":"2026-01-15T12:00:00Z","usageMetadata":{"promptTokenCount":10}}"#;
const OPENCLAW: &str = r#"{"type":"message","id":"s0a","timestamp":"2026-01-15T12:00:00Z","message":{"role":"assistant","usage":{"input":10}}}"#;
const KIMI: &str = r#"{"session_id":"s0a","timestamp":"2026-01-15T12:00:00Z","role":"assistant","token_usage":{"input_tokens":10}}"#;
const OPENCODE: &str = r#"CREATE TABLE message(id,session_id,time_updated,time_created,data); INSERT INTO message VALUES('m','s',1768478400000,NULL,'{"tokens":{"input":10}}')"#;
const KILO: &str = r#"CREATE TABLE session_message(id,session_id,type,time_created,data); INSERT INTO session_message VALUES('m','s','assistant',1,'{"tokens":{"input":10},"time":{"created":1768478400000}}')"#;
const GOOSE: &str = "CREATE TABLE sessions(id,model_config_json,created_at,input_tokens,output_tokens,total_tokens); INSERT INTO sessions VALUES('s','{}',1768478400000,10,2,12)";
const HERMES: &str = "CREATE TABLE session_model_usage(session_id,model,input_tokens,output_tokens,last_seen); INSERT INTO session_model_usage VALUES('s','m',10,2,1768478400000)";
const COPILOT: &str = "CREATE TABLE assistant_usage_events(id,session_id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,created_at); INSERT INTO assistant_usage_events VALUES(1,'s','m',10,2,NULL,NULL,NULL,1768478400000)";
const MINIMAX: &str = "CREATE TABLE local_runtime_token_usage(id,session_id,model,ts,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens); INSERT INTO local_runtime_token_usage VALUES(1,'s','m',1768478400000,10,2,NULL,NULL)";
const ZCODE: &str = "CREATE TABLE model_usage(id,session_id,model_id,provider_id,started_at,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens); INSERT INTO model_usage VALUES('m','s','m',NULL,1768478400000,10,2,NULL,NULL)";

fn fixture(path: &Path, contents: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    if contents.starts_with("CREATE TABLE") {
        rusqlite::Connection::open(path)
            .unwrap()
            .execute_batch(contents)
            .unwrap();
    } else {
        fs::write(path, contents).unwrap();
    }
}

fn client(data: &Path, home: &Path) -> StatsClient {
    StatsClient::new(
        data.to_string_lossy().into_owned(),
        Some(home.to_string_lossy().into_owned()),
    )
    .unwrap()
}

fn records(client: &StatsClient) -> i64 {
    client
        .open()
        .unwrap()
        .db
        .query_row("SELECT count(*) FROM usage_records", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn s0a_preview_sync_ignores_inherited_paths() {
    let cases = [
        ("HOME", "", ".claude/projects/s/usage.jsonl", CLAUDE),
        ("USERPROFILE", "", ".claude/projects/s/usage.jsonl", CLAUDE),
        ("APPDATA", "", "goose/sessions/sessions.db", GOOSE),
        ("LOCALAPPDATA", "", "hermes/state.db", HERMES),
        ("XDG_DATA_HOME", "", "opencode/opencode.db", OPENCODE),
        ("OPENCODE_DB", "bait.db", "bait.db", OPENCODE),
        ("KILO_DB", "bait.db", "bait.db", KILO),
        ("MIMOCODE_HOME", "", "data/mimocode.db", OPENCODE),
        ("MIMOCODE_DB", "bait.db", "bait.db", OPENCODE),
        (
            "MIMOCODE_DISABLE_CHANNEL_DB",
            "",
            "data/mimocode-channel.db",
            OPENCODE,
        ),
        ("ZCODE_DATA_BASE_DIR", "", ".zcode/cli/db/db.sqlite", ZCODE),
        ("ZCODE_SESSION_DB_PATH", "bait.db", "bait.db", ZCODE),
        ("ZCODE_SESSION_DB", "bait.db", "bait.db", ZCODE),
        ("GEMINI_HOME", "", "sessions/bait.json", GEMINI),
        ("GOOSE_PATH_ROOT", "", "data/sessions/sessions.db", GOOSE),
        ("COPILOT_HOME", "", "session-store.db", COPILOT),
        (
            "OPENCLAW_HOME",
            "",
            "agents/a/sessions/bait.jsonl",
            OPENCLAW,
        ),
        (
            "OPENCLAW_STATE_DIR",
            "",
            "agents/a/sessions/bait.jsonl",
            OPENCLAW,
        ),
        ("KIMI_SHARE_DIR", "", "sessions/bait.jsonl", KIMI),
        (
            "MINIMAX_DATA_DIR",
            "",
            "v2/sqlite/runtime-state.sqlite",
            MINIMAX,
        ),
    ];
    let mut leaks = Vec::new();
    for (key, value, file, contents) in cases {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let bait = root.path().join("outside");
        fixture(&bait.join(file), contents);
        // Keep a local positive control so an empty or disabled preview would fail.
        fixture(&home.join(".claude/projects/s/usage.jsonl"), CLAUDE);
        let mut env = ingest::Environment {
            platform: "win32".into(),
            vars: [(key.into(), bait.join(value).to_string_lossy().into_owned())]
                .into_iter()
                .collect(),
            ..Default::default()
        };
        if key == "MIMOCODE_DISABLE_CHANNEL_DB" {
            env.vars.insert(key.into(), "false".into());
            env.vars
                .insert("MIMOCODE_HOME".into(), bait.to_string_lossy().into_owned());
        }
        if !matches!(key, "HOME" | "USERPROFILE") {
            ingest::sync(
                &root.path().join("control"),
                &home,
                &env,
                Clock::System,
                &LocalZone::System,
                &AtomicBool::new(false),
            )
            .map(|result| assert_eq!(result["inserted"], 2, "control for {key}"))
            .unwrap();
        }
        let preview = client(&root.path().join("data"), &home);
        preview.sync_with_env("manual".into(), &env).unwrap();
        let count = records(&preview);
        if count != 1 {
            leaks.push((key, count));
        }
    }
    assert!(leaks.is_empty(), "preview ledger includes bait: {leaks:?}");
}

#[test]
fn antigravity_s0a_preview_ignores_outside_home() {
    use crate::stats::adapters::antigravity_tests::seed;
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let outside = root.path().join("outside");
    let _outside_db = seed(&outside);
    let env = ingest::Environment {
        platform: "win32".into(),
        vars: ["HOME", "USERPROFILE", "GEMINI_HOME"]
            .into_iter()
            .map(|key| (key.into(), outside.to_string_lossy().into_owned()))
            .collect(),
        ..Default::default()
    };
    let preview = client(&root.path().join("data"), &home);
    fs::create_dir_all(&home).unwrap();
    assert_eq!(
        preview
            .sync_with_env("manual".into(), &env)
            .unwrap()
            .inserted,
        0
    );
    let _local_db = seed(&home);
    let bait_uri = reqwest::Url::from_directory_path(&outside).unwrap();
    let summaries = outside.join(".gemini/antigravity-cli/conversation_summaries.db");
    fixture(
        &summaries,
        "CREATE TABLE conversation_summaries(conversation_id, workspace_uris);",
    );
    rusqlite::Connection::open(&summaries)
        .unwrap()
        .execute(
            "INSERT INTO conversation_summaries VALUES ('synthetic', ?1)",
            [json!([bait_uri.as_str()]).to_string()],
        )
        .unwrap();
    let link = home.join(".gemini/antigravity-cli/conversation_summaries.db");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&summaries, &link).unwrap();
    #[cfg(windows)]
    if std::os::windows::fs::symlink_file(&summaries, &link).is_err() {
        // Exercise the reparse-point check without requiring Developer Mode.
        junction(&link, summaries.parent().unwrap());
    }
    let result = preview.sync_with_env("manual".into(), &env).unwrap();
    assert_eq!(result.inserted, 1);
    assert_eq!(
        result.counts.bad_fields, 0,
        "preview tried to open the linked database"
    );
    assert_eq!(records(&preview), 1);
    let project: Option<String> = preview
        .open()
        .unwrap()
        .db
        .query_row("SELECT project_key FROM usage_records", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert!(
        project.is_none(),
        "preview used a workspace from the linked database"
    );
}

#[test]
fn s0a_preview_ignores_zcode_config_outside_home() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let bait = root.path().join("outside");
    let database = bait.join("bait.db");
    fixture(&bait.join(".zcode/cli/db/db.sqlite"), ZCODE);
    fixture(&database, ZCODE);
    fixture(
        &home.join(".zcode/v2/setting.json"),
        &json!({"dataBaseDir":bait}).to_string(),
    );
    fixture(
        &home.join(".zcode/cli/config.json"),
        &json!({"storage":{"sessionDbPath":database}}).to_string(),
    );
    let preview = client(&root.path().join("data"), &home);
    preview.sync_isolated().unwrap();
    assert_eq!(
        records(&preview),
        0,
        "preview followed a ZCode config override"
    );
}

#[test]
fn s0a_preview_skips_a_linked_log_directory() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let bait = root.path().join("outside");
    fixture(&bait.join("usage.jsonl"), CLAUDE);
    fs::create_dir_all(home.join(".claude")).unwrap();
    let link = home.join(".claude").join("projects");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&bait, &link).unwrap();
    #[cfg(windows)]
    junction(&link, &bait);
    let preview = client(&root.path().join("data"), &home);
    preview.sync_isolated().unwrap();
    assert_eq!(records(&preview), 0);
}

#[cfg(windows)]
fn junction(link: &Path, target: &Path) {
    let output = std::process::Command::new("cmd")
        .args(["/C", "mklink", "/J"])
        .arg(link)
        .arg(target)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
}

#[cfg(windows)]
#[test]
fn s0a_acl_discovery_and_last_sync_report_permission_denied() {
    use std::process::Command;
    struct DenyList<'a> {
        path: &'a Path,
        sid: String,
    }
    impl Drop for DenyList<'_> {
        fn drop(&mut self) {
            assert!(Command::new("icacls")
                .arg(self.path)
                .args(["/remove:d", &self.sid])
                .output()
                .unwrap()
                .status
                .success());
        }
    }
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let logs = home.join(".claude/projects");
    fixture(&logs.join("usage.jsonl"), CLAUDE);
    let preview = client(&root.path().join("data"), &home);
    let output = Command::new("whoami")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let output = String::from_utf8_lossy(&output.stdout);
    let sid = output
        .split('"')
        .find(|value| value.starts_with("S-1-"))
        .unwrap();
    let sid = format!("*{sid}");
    let output = Command::new("icacls")
        .arg(&logs)
        .args(["/deny", &format!("{sid}:(RD)")])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let denied = DenyList { path: &logs, sid };
    let error = match fs::read_dir(&logs) {
        Err(error) => error,
        Ok(entries) => {
            drop(entries);
            let privileges = Command::new("whoami")
                .args(["/priv", "/fo", "csv", "/nh"])
                .output();
            let backup_enabled = privileges.as_ref().is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).lines().any(|row| {
                        row.starts_with("\"SeBackupPrivilege\",") && row.ends_with(",\"Enabled\"")
                    })
            });
            if backup_enabled {
                use std::io::Write;
                writeln!(
                    std::io::stderr(),
                    "Skipping Windows ACL discovery test: read_dir succeeded after denying \
                     directory listing and SeBackupPrivilege is enabled"
                )
                .unwrap();
                return;
            }
            let acl = Command::new("icacls").arg(&logs).output();
            panic!(
                "read_dir({logs:?}) succeeded after denying {}:(RD), but an enabled \
                 SeBackupPrivilege could not be confirmed.\nwhoami /priv: {privileges:?}\n\
                 icacls: {acl:?}",
                denied.sid
            );
        }
    };
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    assert_eq!(error.raw_os_error(), Some(5));
    eprintln!("Windows read_dir: {error:?}");
    // A completely missing directory, outside the denied one, remains a quiet miss.
    let missing_error = fs::read_dir(home.join(".missing/child")).unwrap_err();
    assert_eq!(missing_error.kind(), std::io::ErrorKind::NotFound);
    eprintln!("Windows read_dir missing: {missing_error:?}");
    let discovery = serde_json::to_value(preview.discovery(true).unwrap()).unwrap();
    preview.sync_isolated().unwrap();
    let sources = serde_json::to_value(preview.sources().unwrap()).unwrap();
    assert_eq!(records(&preview), 0);
    drop(denied);
    let issue =
        json!([{"source":"claude","permission_denied":1,"io_errors":0,"unreadable_entries":0}]);
    assert_eq!(discovery["discovery_issues"], issue);
    assert_eq!(sources["discovery_issues"], issue);
    let refreshed = serde_json::to_value(preview.discovery(true).unwrap()).unwrap();
    assert_eq!(refreshed["sources"][0]["source"], "claude");
    preview.sync_isolated().unwrap();
    assert_eq!(records(&preview), 1);
    let sources = serde_json::to_value(preview.sources().unwrap()).unwrap();
    assert_eq!(sources["discovery_issues"], json!([]));
}
