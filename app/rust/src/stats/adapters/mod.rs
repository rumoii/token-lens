mod aider;
mod claude;
mod cline;
mod codebuddy;
mod codex;
mod commandcode;
#[path = "continue.rs"]
mod continue_;
mod dsh;
mod gemini;
mod grok;
mod kimi;
mod lines;
mod num;
mod openclaw;
mod openhands;
mod pi;
mod project;
mod qwen;
mod trae;
mod zstd;
use super::{jscompat::LocalZone, Error, Result};
#[cfg(test)]
use lines::file_tag;
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
                assert_eq!(json!(records), row["records"], "{file}");
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
    ("codex", 4),
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
