mod aider;
mod anythingllm;
mod claude;
mod cline;
mod codebuddy;
mod codex;
mod commandcode;
#[path = "continue.rs"]
mod continue_;
mod copilot;
mod cursor;
mod dsh;
mod gemini;
mod goose;
mod grok;
mod hermes;
mod kilo;
mod kimi;
mod lines;
mod mimo;
mod minimax;
mod num;
mod openclaw;
mod opencode;
mod openhands;
mod pi;
mod project;
mod qwen;
mod sqlite;
mod trae;
mod zcode;
mod zed;
mod zstd;
use super::{jscompat::LocalZone, Error, Result};
#[cfg(test)]
pub(super) use lines::file_tag;
#[cfg(test)]
use num::plus;
use serde_json::{json, Value};
use std::path::Path;
pub fn parse(
    source: &str,
    identity: &str,
    file: &Path,
    zone: &LocalZone,
) -> Result<(Vec<Value>, Value)> {
    let mut notes = json!({"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0});
    if matches!(
        source,
        "hermes"
            | "cursor"
            | "opencode"
            | "kilo"
            | "goose"
            | "zed"
            | "copilot"
            | "mimo"
            | "minimax"
            | "zcode"
            | "anythingllm"
    ) {
        let csv = source == "cursor"
            && Path::new(identity)
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("csv"));
        if source == "cursor"
            && !csv
            && !Path::new(identity).extension().is_some_and(|e| {
                ["vscdb", "sqlite", "db"]
                    .iter()
                    .any(|s| e.eq_ignore_ascii_case(s))
            })
        {
            return Ok((Vec::new(), notes));
        }
        if !csv && !file.exists() {
            return Ok((Vec::new(), notes));
        }
        let records = match source {
            "hermes" => hermes::parse(file, zone, &mut notes)?,
            "cursor" if csv => cursor::csv(identity, file, zone, &mut notes)?,
            "cursor" => cursor::parse(identity, file, zone, &mut notes)?,
            "opencode" => opencode::parse(identity, file, source, zone, &mut notes)?,
            "mimo" => mimo::parse(identity, file, zone, &mut notes)?,
            "kilo" => kilo::parse(file, zone, &mut notes)?,
            "goose" => goose::parse(file, zone, &mut notes)?,
            "zed" => zed::parse(file, zone, &mut notes)?,
            "copilot" => copilot::parse(identity, file, zone, &mut notes)?,
            "minimax" => minimax::parse(file, zone, &mut notes)?,
            "zcode" => zcode::parse(file, zone, &mut notes)?,
            "anythingllm" => anythingllm::parse(file, zone, &mut notes)?,
            _ => unreachable!(),
        };
        return Ok((records, notes));
    }
    if matches!(
        source,
        "cline"
            | "gemini"
            | "openhands"
            | "trae"
            | "openclaw"
            | "kimi"
            | "codebuddy"
            | "commandcode"
    ) && !file.exists()
    {
        return Ok((Vec::new(), notes));
    }
    let mut bytes = match std::fs::read(file) {
        Ok(bytes) => bytes,
        Err(error) if source == "continue" && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), notes))
        }
        Err(error) => return Err(error.into()),
    };
    if source == "codex" && identity.ends_with(".zst") {
        bytes = zstd::decode(&bytes)?;
    }
    let records = match source {
        "claude" => claude::parse(identity, &bytes, zone, &mut notes),
        "codex" => codex::parse(identity, &bytes, zone, &mut notes)?,
        "qwen" => qwen::parse(identity, file, &bytes, zone, &mut notes)?,
        "dsh" => dsh::parse(identity, file, &bytes, zone, &mut notes)?,
        "grok" => grok::parse(identity, file, &bytes, zone, &mut notes)?,
        "aider" => aider::parse(identity, file, &bytes, zone, &mut notes)?,
        "pi" => pi::parse(identity, file, &bytes, zone, &mut notes)?,
        "commandcode" => commandcode::parse(identity, file, &bytes, zone, &mut notes)?,
        "cline" => cline::parse(identity, file, &bytes, zone, &mut notes)?,
        "gemini" => gemini::parse(identity, file, &bytes, zone, &mut notes)?,
        "continue" => continue_::parse(identity, file, &bytes, zone, &mut notes)?,
        "trae" => trae::parse(identity, file, &bytes, zone, &mut notes)?,
        "openclaw" => openclaw::parse(identity, file, &bytes, zone, &mut notes)?,
        "kimi" => kimi::parse(identity, file, &bytes, zone, &mut notes)?,
        "openhands" => openhands::parse(identity, file, &bytes, zone, &mut notes)?,
        "codebuddy" => codebuddy::parse(identity, file, &bytes, zone, &mut notes)?,
        _ => return Err(Error(format!("unknown source: {source}"))),
    };
    Ok((records, notes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sqlite_sources_b3() {
        let cases = [
            ("hermes", "CREATE TABLE session_model_usage(session_id,model,input_tokens,output_tokens,last_seen); INSERT INTO session_model_usage VALUES('s','m',10,2,1768478400000)"),
            ("cursor", "CREATE TABLE ItemTable(key,value); INSERT INTO ItemTable VALUES('composerData','[{\"id\":\"s\",\"model\":\"m\",\"createdAt\":1768478400000,\"conversation\":[{\"role\":\"user\",\"tokenCount\":10}]}]')"),
            ("opencode", "CREATE TABLE message(id,session_id,time_updated,time_created,data); INSERT INTO message VALUES('m','s',1768478400000,NULL,'{\"tokens\":{\"input\":10}}')"),
            ("mimo", "CREATE TABLE message(id,session_id,time_updated,time_created,data); INSERT INTO message VALUES('m','s',1768478400000,NULL,'{\"tokens\":{\"input\":10}}')"),
            ("kilo", "CREATE TABLE session_message(id,session_id,type,time_created,data); INSERT INTO session_message VALUES('m','s','assistant',1,'{\"tokens\":{\"input\":10},\"time\":{\"created\":1768478400000}}')"),
            ("goose", "CREATE TABLE sessions(id,model_config_json,created_at,input_tokens,output_tokens,total_tokens); INSERT INTO sessions VALUES('s','{}',1768478400000,10,2,12)"),
            ("zed", "CREATE TABLE threads(id,updated_at,data_type,data); INSERT INTO threads VALUES('s',1768478400000,'json','{\"cumulative_token_usage\":{\"input_tokens\":10}}')"),
            ("copilot", "CREATE TABLE assistant_usage_events(id,session_id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,created_at); INSERT INTO assistant_usage_events VALUES(1,'s','m',10,2,NULL,NULL,NULL,1768478400000)"),
            ("minimax", "CREATE TABLE local_runtime_token_usage(id,session_id,model,ts,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens); INSERT INTO local_runtime_token_usage VALUES(1,'s','m',1768478400000,10,2,NULL,NULL)"),
            ("zcode", "CREATE TABLE model_usage(id,session_id,model_id,provider_id,started_at,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens); INSERT INTO model_usage VALUES('m','s','m',NULL,1768478400000,10,2,NULL,NULL)"),
            ("anythingllm", "CREATE TABLE workspace_chats(id,workspaceId,response,createdAt); INSERT INTO workspace_chats VALUES(1,7,'{\"metrics\":{\"prompt_tokens\":10}}',1768478400000)"),
        ];
        let mut failures = Vec::new();
        for (source, sql) in cases {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("input.db");
            let db = rusqlite::Connection::open(&file).unwrap();
            db.execute_batch(sql).unwrap();
            drop(db);
            match parse(source, "identity.db", &file, &LocalZone::Fixed(480)) {
                Ok((records, notes)) => {
                    assert_eq!(records.len(), 1, "{source}: {notes}");
                    assert_eq!(records[0]["source"], source);
                    assert_eq!(records[0]["input_tokens"], 10);
                }
                Err(e) => failures.push(format!("{source}: {e}")),
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
    #[test]
    fn dispatch_before_read_b3() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing");
        for source in [
            "hermes",
            "cursor",
            "opencode",
            "kilo",
            "goose",
            "zed",
            "copilot",
            "mimo",
            "minimax",
            "zcode",
            "anythingllm",
        ] {
            let (records, notes) =
                parse(source, "identity.db", &missing, &LocalZone::Fixed(480)).unwrap();
            assert!(records.is_empty(), "{source}");
            assert_eq!(
                notes,
                json!({"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0})
            );
        }
        assert!(parse("cursor", "identity.CSV", &missing, &LocalZone::Fixed(480)).is_err());
        assert!(
            parse("cursor", "identity.json", &missing, &LocalZone::Fixed(480))
                .unwrap()
                .0
                .is_empty()
        );
        assert!(
            parse("cursor", "identity", dir.path(), &LocalZone::Fixed(480))
                .unwrap()
                .0
                .is_empty()
        );
    }
    #[test]
    fn adapters_match_node() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        for line in include_str!("../../../tests/golden/adapters.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "adapter_record" {
                let file = row["file"].as_str().unwrap();
                let (records, notes) = parse(
                    row["source"].as_str().unwrap(),
                    file,
                    &root.join(file),
                    &LocalZone::Fixed(480),
                )
                .unwrap();
                let mut expected = row["records"].clone();
                if row["source"] == "codex" && file.starts_with("test/fixtures/parity/codex.jsonl")
                {
                    // Intentional Rust-only short-ID identity rule; retain the Node golden verbatim.
                    assert_eq!(expected[0]["record_key"], "codex|codex-s|r1");
                    expected[0]["record_key"] = json!(format!(
                        "codex|codex-s|{}:2",
                        file_tag(file.strip_suffix(".zst").unwrap_or(file))
                    ));
                    expected[0]["replaces"] = json!(["codex|codex-s|r1"]);
                }
                assert_eq!(json!(records), expected, "{file}");
                assert_eq!(notes, row["notes"], "{file}");
            }
            if row["type"] == "identity" {
                if let Some(file) = row["file"].as_str() {
                    assert_eq!(
                        file_tag(file.strip_suffix(".zst").unwrap_or(file)),
                        row["expected"].as_str().unwrap()
                    );
                } else {
                    assert_eq!(
                        super::super::ledger::payload_hash(&row["record"]),
                        row["expected"].as_str().unwrap()
                    );
                    assert_eq!(
                        super::super::ledger::payload_input(&row["record"])
                            .as_bytes()
                            .iter()
                            .map(|b| format!("{b:02x}"))
                            .collect::<String>(),
                        row["canonical_utf8_hex"].as_str().unwrap()
                    );
                }
            }
            if row["fn"] == "zstd" {
                let bytes = std::fs::read(root.join(format!(
                    "test/fixtures/parity/zstd-{}.bin",
                    row["name"].as_str().unwrap()
                )))
                .unwrap();
                let result = zstd::decode(&bytes);
                if let Some(error) = row["error"].as_str() {
                    assert_eq!(result.unwrap_err().0, error);
                } else {
                    assert_eq!(
                        result
                            .unwrap()
                            .iter()
                            .map(|byte| format!("{byte:02x}"))
                            .collect::<String>(),
                        row["expected"].as_str().unwrap()
                    );
                }
            }
        }
        assert_eq!(plus(None, None), None);
        assert_eq!(plus(None, Some(3)), Some(3));
    }
}

pub const PARSER_REV: &[(&str, i64)] = &[
    ("claude", 3),
    ("codex", 5),
    ("qwen", 7),
    ("dsh", 3),
    ("grok", 3),
    ("aider", 5),
    ("pi", 6),
    ("hermes", 3),
    ("cline", 3),
    ("gemini", 3),
    ("cursor", 3),
    ("opencode", 6),
    ("kilo", 3),
    ("openhands", 1),
    ("goose", 5),
    ("zed", 3),
    ("continue", 3),
    ("trae", 4),
    ("copilot", 4),
    ("openclaw", 5),
    ("mimo", 4),
    ("kimi", 5),
    ("minimax", 4),
    ("codebuddy", 4),
    ("zcode", 1),
    ("commandcode", 1),
    ("anythingllm", 1),
];
pub fn parser_rev(source: &str) -> i64 {
    PARSER_REV
        .iter()
        .find(|(s, _)| *s == source)
        .map_or(1, |(_, rev)| *rev)
}
#[cfg(test)]
mod revision_tests {
    #[test]
    fn node_parser_revisions() {
        for line in include_str!("../../../tests/golden/parser-rev.jsonl").lines() {
            let row: serde_json::Value = serde_json::from_str(line).unwrap();
            if row["source"] == "codex" {
                // Node is the independent rollback path; see specs/stats.md, allowed differences.
                assert_eq!(row["expected"], 4);
                assert_eq!(super::parser_rev("codex"), 5);
                continue;
            }
            assert_eq!(
                super::parser_rev(row["source"].as_str().unwrap()),
                row["expected"].as_i64().unwrap(),
                "{line}"
            );
        }
    }
}

#[cfg(test)]
mod b2_tests {
    use super::*;
    #[test]
    fn adapters_match_node_b2() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        for line in include_str!("../../../tests/golden/adapters-b2.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "adapter_record" {
                let file = row["file"].as_str().unwrap();
                let result = parse(
                    row["source"].as_str().unwrap(),
                    file,
                    &root.join(file),
                    &LocalZone::Fixed(480),
                );
                if row["error"] == true {
                    assert!(result.is_err(), "{file}");
                } else {
                    let (records, notes) = result.unwrap_or_else(|e| panic!("{file}: {e}"));
                    assert_eq!(json!(records), row["records"], "records {file}");
                    assert_eq!(notes, row["notes"], "notes {file}");
                }
            } else if row["type"] == "identity" {
                if let Some(file) = row["file"].as_str() {
                    assert_eq!(file_tag(file), row["expected"].as_str().unwrap());
                } else {
                    assert_eq!(
                        super::super::ledger::payload_hash(&row["record"]),
                        row["expected"].as_str().unwrap()
                    );
                    assert_eq!(
                        super::super::ledger::payload_input(&row["record"])
                            .as_bytes()
                            .iter()
                            .map(|b| format!("{b:02x}"))
                            .collect::<String>(),
                        row["canonical_utf8_hex"].as_str().unwrap()
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod b3_tests {
    use super::*;
    #[test]
    fn adapters_match_node_b3() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut setup = Value::Null;
        let mut scenarios = 0;
        let mut records_count = 0;
        let mut failures = 0;
        let mut wal = 0;
        for line in include_str!("../../../tests/golden/adapters-b3.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            match row["type"].as_str().unwrap() {
                "setup" => setup = row,
                "adapter_record" => {
                    let dir = tempfile::tempdir().unwrap();
                    let writers = sqlite::materialize(&repo, dir.path(), &setup);
                    let file = row["file"].as_str().unwrap();
                    let actual = dir.path().join(file);
                    let snapshots = if setup["kind"].as_str().unwrap().starts_with("wal-") {
                        wal += 1;
                        vec![
                            actual.clone(),
                            std::path::PathBuf::from(format!("{}-wal", actual.display())),
                        ]
                        .into_iter()
                        .map(|p| {
                            let bytes = std::fs::read(&p).unwrap();
                            (p, bytes)
                        })
                        .collect::<Vec<_>>()
                    } else {
                        Vec::new()
                    };
                    let result = parse(
                        row["source"].as_str().unwrap(),
                        file,
                        &actual,
                        &LocalZone::Fixed(480),
                    );
                    for (path, before) in snapshots {
                        assert_eq!(
                            std::fs::read(&path).unwrap(),
                            before,
                            "WAL bytes changed: {file}"
                        );
                    }
                    scenarios += 1;
                    if row["error"] == true {
                        failures += 1;
                        assert!(result.is_err(), "expected file failure: {file}");
                    } else {
                        let (records, notes) = result.unwrap_or_else(|e| panic!("{file}: {e}"));
                        records_count += records.len();
                        assert_eq!(json!(records), row["records"], "records: {file}");
                        assert_eq!(notes, row["notes"], "notes: {file}");
                    }
                    drop(writers);
                }
                "identity" => {
                    if let Some(file) = row["file"].as_str() {
                        assert_eq!(file_tag(file), row["expected"].as_str().unwrap());
                    } else {
                        assert_eq!(
                            super::super::ledger::payload_hash(&row["record"]),
                            row["expected"].as_str().unwrap()
                        );
                        assert_eq!(
                            super::super::ledger::payload_input(&row["record"])
                                .as_bytes()
                                .iter()
                                .map(|b| format!("{b:02x}"))
                                .collect::<String>(),
                            row["canonical_utf8_hex"].as_str().unwrap()
                        );
                    }
                }
                _ => {}
            }
        }
        println!("b3: {scenarios} adapter scenarios, {records_count} records, {failures} file failures, {wal} WAL scenarios");
    }
}

#[cfg(test)]
mod ledger_b3_tests {
    use super::super::{
        clock::Clock,
        ingest,
        ledger::{self, Ledger},
        service,
    };
    use super::*;
    use std::sync::atomic::AtomicBool;
    fn setup_b3(home: &Path) {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let setup: Value = include_str!("../../../tests/golden/ingest-b3.jsonl")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|r| r["type"] == "setup")
            .unwrap();
        for entry in setup["files"].as_array().unwrap() {
            let setup = json!({"source":entry["source"],"file":entry["target"],"kind":"seed","seed":entry["input"]});
            assert!(sqlite::materialize(&repo, home, &setup).is_empty());
        }
    }
    fn environment(home: &Path) -> ingest::Environment {
        ingest::Environment {
            platform: "win32".into(),
            vars: ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"]
                .into_iter()
                .map(|key| (key.into(), home.join(key).to_string_lossy().into_owned()))
                .collect(),
        }
    }
    #[test]
    fn ingestion_matches_node_b3() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let data = dir.path().join("data");
        setup_b3(&home);
        let env = environment(&home);
        for line in include_str!("../../../tests/golden/ingest-b3.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "run" {
                let mut actual = ingest::sync(
                    &data,
                    &home,
                    &env,
                    Clock::Fixed(1768478400000),
                    &LocalZone::Fixed(480),
                    &AtomicBool::new(false),
                )
                .unwrap();
                actual["durationMs"] = json!("<volatile>");
                assert_eq!(actual, row["expected"], "run {}", row["index"]);
            }
        }
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
        let mut actual = ledger::rows(
            &ledger.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[],
        )
        .unwrap();
        for row in &mut actual {
            row.as_object_mut().unwrap().remove("id");
            row["ingested_at"] = json!("<volatile>");
            row["source_file"] =
                json!(&row["source_file"].as_str().unwrap()[home.to_string_lossy().len() + 1..]);
        }
        let expected = include_str!("../../../tests/golden/ingest-b3.jsonl")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|r| r["type"] == "ledger_row")
            .map(|r| r["expected"].clone())
            .collect::<Vec<_>>();
        assert_eq!(actual, expected);
        for line in include_str!("../../../tests/golden/ingest-b3.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "query" {
                let actual = if row["fn"] == "summary" {
                    service::summary(&ledger, &json!({}), 480, "Asia/Shanghai")
                } else {
                    service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai")
                }
                .unwrap();
                assert_eq!(actual, row["expected"], "{}", row["fn"]);
            }
        }
    }
    #[test]
    fn all_twenty_seven_sources_sync_and_repeat_b3() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let data = dir.path().join("data");
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let setup: Value = include_str!("../../../tests/golden/ingest-b2.jsonl")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|r| r["type"] == "setup")
            .unwrap();
        for entry in setup["files"].as_array().unwrap() {
            let target = home.join(entry["target"].as_str().unwrap());
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::copy(repo.join(entry["input"].as_str().unwrap()), target).unwrap();
        }
        setup_b3(&home);
        let env = environment(&home);
        // The same sync and service entry points are called inside StatsClient; no process environment is read.
        let sync = || {
            ingest::sync(
                &data,
                &home,
                &env,
                Clock::Fixed(1768478400000),
                &LocalZone::Fixed(480),
                &AtomicBool::new(false),
            )
            .unwrap()
        };
        let first = sync();
        assert_eq!(first["counts"]["read_failed"], 0);
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
        let summary = service::summary(&ledger, &json!({}), 480, "Asia/Shanghai").unwrap();
        let breakdown =
            service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai").unwrap();
        let mut actual = breakdown["groups"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["key"].as_str().unwrap())
            .collect::<Vec<_>>();
        actual.sort();
        let mut expected = PARSER_REV
            .iter()
            .map(|(source, _)| *source)
            .collect::<Vec<_>>();
        expected.sort();
        assert_eq!(actual, expected);
        assert_eq!(actual.len(), 27);
        let count = summary["totals"]["record_count"].as_i64().unwrap();
        assert_eq!(first["inserted"], count);
        assert_eq!(
            breakdown["groups"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["record_count"].as_i64().unwrap())
                .sum::<i64>(),
            count
        );
        let second = sync();
        assert_eq!(second["inserted"], 0);
        assert_eq!(second["updated"], 0);
        assert_eq!(second["unchanged"], count);
        assert_eq!(
            service::summary(&ledger, &json!({}), 480, "Asia/Shanghai").unwrap(),
            summary
        );
        assert_eq!(
            service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai").unwrap(),
            breakdown
        );
    }
}

#[cfg(test)]
mod ledger_b2_tests {
    use super::super::{
        clock::Clock,
        ingest,
        ledger::{self, Ledger},
        service,
    };
    use super::*;
    use std::sync::atomic::AtomicBool;
    fn setup(home: &Path, all: bool) {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let row: Value = include_str!("../../../tests/golden/ingest-b2.jsonl")
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
            .find(|r| r["type"] == "setup")
            .unwrap();
        for entry in row["files"].as_array().unwrap() {
            if all || entry["ledger"] == true {
                let target = home.join(entry["target"].as_str().unwrap());
                std::fs::create_dir_all(target.parent().unwrap()).unwrap();
                std::fs::copy(root.join(entry["input"].as_str().unwrap()), target).unwrap();
            }
        }
    }
    fn environment(home: &Path) -> ingest::Environment {
        ingest::Environment {
            platform: "win32".into(),
            vars: [
                (
                    "APPDATA".into(),
                    home.join("APPDATA").to_string_lossy().into(),
                ),
                (
                    "LOCALAPPDATA".into(),
                    home.join("LOCALAPPDATA").to_string_lossy().into(),
                ),
                (
                    "XDG_DATA_HOME".into(),
                    home.join("XDG_DATA_HOME").to_string_lossy().into(),
                ),
            ]
            .into(),
        }
    }
    #[test]
    fn ingestion_matches_node_b2() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let data = dir.path().join("data");
        setup(&home, false);
        let env = environment(&home);
        for line in include_str!("../../../tests/golden/ingest-b2.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "run" {
                let mut result = ingest::sync(
                    &data,
                    &home,
                    &env,
                    Clock::Fixed(1768478400000),
                    &LocalZone::Fixed(480),
                    &AtomicBool::new(false),
                )
                .unwrap();
                result["durationMs"] = json!("<volatile>");
                assert_eq!(result, row["expected"], "run {}", row["index"]);
            }
        }
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
        let mut actual = ledger::rows(
            &ledger.db,
            "SELECT * FROM usage_records ORDER BY record_key",
            &[],
        )
        .unwrap();
        for row in &mut actual {
            row.as_object_mut().unwrap().remove("id");
            row["ingested_at"] = json!("<volatile>");
            row["source_file"] =
                json!(&row["source_file"].as_str().unwrap()[home.to_string_lossy().len() + 1..]);
        }
        let expected = include_str!("../../../tests/golden/ingest-b2.jsonl")
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
            .filter(|r| r["type"] == "ledger_row")
            .map(|r| r["expected"].clone())
            .collect::<Vec<_>>();
        assert_eq!(actual, expected);
        for line in include_str!("../../../tests/golden/ingest-b2.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "query" {
                let actual = if row["fn"] == "summary" {
                    service::summary(&ledger, &json!({}), 480, "Asia/Shanghai")
                } else {
                    service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai")
                }
                .unwrap();
                assert_eq!(actual, row["expected"], "{}", row["fn"]);
            }
        }
    }
    #[test]
    fn all_sixteen_sources_sync_and_repeat() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let data = dir.path().join("data");
        setup(&home, true);
        let environment = environment(&home);
        // These are the same sync and query entry points used inside StatsClient.
        let first = ingest::sync(
            &data,
            &home,
            &environment,
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(480),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(first["counts"]["read_failed"], 0);
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
        let summary = service::summary(&ledger, &json!({}), 480, "Asia/Shanghai").unwrap();
        let breakdown =
            service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai").unwrap();
        let mut sources = breakdown["groups"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["key"].as_str().unwrap())
            .collect::<Vec<_>>();
        sources.sort();
        assert_eq!(
            sources,
            [
                "aider",
                "claude",
                "cline",
                "codebuddy",
                "codex",
                "commandcode",
                "continue",
                "dsh",
                "gemini",
                "grok",
                "kimi",
                "openclaw",
                "openhands",
                "pi",
                "qwen",
                "trae"
            ]
        );
        let count = summary["totals"]["record_count"].as_i64().unwrap();
        assert_eq!(first["inserted"], count);
        assert_eq!(
            breakdown["groups"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["record_count"].as_i64().unwrap())
                .sum::<i64>(),
            count
        );
        let second = ingest::sync(
            &data,
            &home,
            &environment,
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(480),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(second["inserted"], 0);
        assert_eq!(second["updated"], 0);
        assert_eq!(second["unchanged"], count);
        assert_eq!(
            service::summary(&ledger, &json!({}), 480, "Asia/Shanghai").unwrap(),
            summary
        );
        assert_eq!(
            service::breakdown(&ledger, &json!({"by":"source"}), 480, "Asia/Shanghai").unwrap(),
            breakdown
        );
    }
}
