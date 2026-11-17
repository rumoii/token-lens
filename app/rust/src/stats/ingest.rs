pub use super::discovery::Environment;
use super::{
    adapters,
    clock::Clock,
    discovery,
    jscompat::{self, LocalZone},
    ledger::Ledger,
    lock::SyncLock,
    pricing, Error, Result,
};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};

struct Parsed {
    file: String,
    records: Vec<Value>,
}

#[cfg(test)]
mod e4b_real_tests {
    use super::*;
    fn collect(root: &Path, name: Option<&str>, files: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(root).unwrap() {
            let entry = entry.unwrap();
            let ty = entry.file_type().unwrap();
            if ty.is_symlink() {
                continue;
            }
            if ty.is_dir() {
                collect(&entry.path(), name, files);
            } else if name.map_or_else(
                || entry.path().extension().is_some_and(|e| e == "jsonl"),
                |n| entry.file_name() == n,
            ) {
                files.push(entry.path());
            }
        }
    }
    fn numeric_methods(value: &mut Value) {
        if let Some(o) = value.as_object_mut() {
            if let Some(method) = o.get_mut("method") {
                *method = json!(match method.as_str().unwrap() {
                    "client_reported" => 1,
                    "log_timestamps" => 2,
                    "content_event_proxy" => 3,
                    _ => panic!("unknown method"),
                });
            }
            for v in o.values_mut() {
                numeric_methods(v);
            }
        } else if let Some(a) = value.as_array_mut() {
            for v in a {
                numeric_methods(v);
            }
        }
    }
    fn check_rates(actual: &Value, expected: &mut Value) {
        if let Some(o) = expected.as_object_mut() {
            for (k, v) in o {
                if k == "tokens_per_second" {
                    assert!((actual[k].as_f64().unwrap() - v.as_f64().unwrap()).abs() < 1e-10);
                    *v = actual[k].clone();
                } else {
                    check_rates(&actual[k], v);
                }
            }
        } else if let Some(a) = expected.as_array_mut() {
            assert_eq!(actual.as_array().unwrap().len(), a.len());
            for (i, v) in a.iter_mut().enumerate() {
                check_rates(&actual[i], v);
            }
        }
    }
    #[tokio::test]
    #[ignore = "Requires explicit read-only E4b source home and independent numeric audits"]
    async fn e4b_real_sources_adapter_ledger_ffi_match_independent_audits() {
        let home = std::path::PathBuf::from(std::env::var("TOKEN_LENS_E4B_LOG_HOME").unwrap());
        let audits = std::path::PathBuf::from(std::env::var("TOKEN_LENS_E4B_AUDITS").unwrap());
        for source in ["qwen", "pi", "opencode", "grok", "claude"] {
            let mut files = Vec::new();
            match source {
                "qwen" => collect(&home.join(".qwen/usage"), None, &mut files),
                "pi" => collect(&home.join(".pi/agent/sessions"), None, &mut files),
                "claude" => collect(&home.join(".claude/projects"), None, &mut files),
                "grok" => collect(
                    &home.join(".grok/sessions"),
                    Some("updates.jsonl"),
                    &mut files,
                ),
                "opencode" => files.push(home.join(".local/share/opencode/opencode.db")),
                _ => unreachable!(),
            }
            files.sort();
            let temp = tempfile::tempdir().unwrap();
            let snapshot_home = temp.path().join("snapshot");
            for file in &mut files {
                let copy = snapshot_home.join(file.strip_prefix(&home).unwrap());
                std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
                if source == "opencode" {
                    // A read-only connection captures committed WAL data consistently.
                    let db = rusqlite::Connection::open_with_flags(
                        &*file,
                        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
                    )
                    .unwrap();
                    db.execute("VACUUM INTO ?", [copy.to_str().unwrap()])
                        .unwrap();
                } else {
                    // Both implementations consume exactly these bytes while live logs keep growing.
                    std::fs::write(&copy, std::fs::read(&*file).unwrap()).unwrap();
                }
                *file = copy;
            }
            let independent = std::process::Command::new("python")
                .arg(audits.join(format!("e4b-audit-{source}.py")))
                .env(
                    "TOKEN_LENS_E4B_AUDIT_HOME",
                    snapshot_home.canonicalize().unwrap(),
                )
                .output()
                .unwrap();
            if !independent.status.success() {
                let error = String::from_utf8_lossy(&independent.stderr);
                let category = [
                    "FileNotFoundError",
                    "OSError",
                    "SyntaxError",
                    "ValueError",
                    "KeyError",
                    "TypeError",
                ]
                .into_iter()
                .find(|kind| error.contains(kind))
                .unwrap_or("unknown");
                panic!("independent audit failed: {category}");
            }
            let expected: Value = serde_json::from_slice(&independent.stdout).unwrap();
            std::fs::write(
                audits.join(format!("e4b-audit-{source}.json")),
                &independent.stdout,
            )
            .unwrap();
            assert_eq!(files.len() as u64, expected["files"].as_u64().unwrap());
            let data = temp.path().join("data");
            let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
            let mut parsed = Vec::new();
            for file in files {
                let identity = file.to_string_lossy().to_string();
                let (mut records, _) =
                    adapters::parse(source, &identity, &file, &LocalZone::Fixed(0)).unwrap();
                records.retain(|r| jscompat::truthy(&r["observed_at"]));
                parsed.push(Parsed {
                    file: identity,
                    records,
                });
            }
            let mut totals = json!({"counts":{"cross_file_copies":0},"anomalies":[]});
            let elsewhere = settle(&mut parsed, &mut totals);
            for file in parsed {
                let result = ledger
                    .batch(
                        &file.records,
                        Some(&file.file),
                        Some(adapters::parser_rev(source)),
                        elsewhere.get(&file.file).map_or(&[], Vec::as_slice),
                        pricing::cost_of,
                    )
                    .unwrap();
                assert_eq!(result["rejected"], 0);
            }
            let client = crate::api::stats::StatsClient::new_with_fixed_clock(
                data.to_string_lossy().into_owned(),
                Some(temp.path().join("home").to_string_lossy().into_owned()),
                1768478400000,
            )
            .unwrap();
            let result = client
                .breakdown("source".into(), Default::default(), 0)
                .unwrap();
            let mut timing =
                serde_json::to_value(result.groups[0].timing.as_ref().unwrap()).unwrap();
            if source == "grok" {
                timing = timing["turn"].clone();
            }
            numeric_methods(&mut timing);
            let mut expected_timing = expected["timing"].clone();
            check_rates(&timing, &mut expected_timing);
            assert_eq!(timing, expected_timing, "{source}");
            // Numeric values only: never emit records, identifiers, content, or source paths.
            println!("{}", serde_json::to_string(&timing).unwrap());
            client.shutdown().await;
        }
    }
}

fn settle(parsed: &mut [Parsed], totals: &mut Value) -> HashMap<String, Vec<String>> {
    let mut starts = Vec::new();
    let mut holders: Vec<(String, Vec<(usize, usize)>)> = Vec::new();
    let mut indexes = HashMap::new();
    for (file_index, file) in parsed.iter().enumerate() {
        starts.push(
            file.records
                .iter()
                .filter_map(|r| r["observed_at"].as_str())
                .min()
                .unwrap_or("")
                .to_owned(),
        );
        for (record_index, record) in file.records.iter().enumerate() {
            if record["kind"].as_str().unwrap_or("event") != "event" {
                continue;
            }
            let Some(key) = record["record_key"].as_str().filter(|s| !s.is_empty()) else {
                continue;
            };
            let index = *indexes.entry(key.to_owned()).or_insert_with(|| {
                holders.push((key.to_owned(), Vec::new()));
                holders.len() - 1
            });
            if !holders[index].1.iter().any(|(i, _)| *i == file_index) {
                holders[index].1.push((file_index, record_index));
            }
        }
    }
    let mut elsewhere: HashMap<String, Vec<String>> = HashMap::new();
    let mut dropped: HashMap<usize, HashSet<String>> = HashMap::new();
    for (key, mut holders) in holders {
        if holders.len() < 2 {
            continue;
        }
        holders.sort_by(|(a, _), (b, _)| {
            jscompat::locale_compare(&starts[*a], &starts[*b])
                .then_with(|| jscompat::locale_compare(&parsed[*a].file, &parsed[*b].file))
        });
        let (owner, index) = holders[0];
        let mut kept = parsed[owner].records[index].clone();
        let mut replaces: Vec<Value> = kept["replaces"].as_array().cloned().unwrap_or_default();
        for (file_index, record_index) in &holders[1..] {
            let copy = &parsed[*file_index].records[*record_index];
            let file = &parsed[*file_index].file;
            let old = copy["replaces"].as_array().cloned().unwrap_or_default();
            for value in &old {
                if !replaces.contains(value) {
                    replaces.push(value.clone());
                }
            }
            let taken = elsewhere.entry(file.clone()).or_default();
            for value in std::iter::once(key.clone())
                .chain(old.iter().filter_map(|v| v.as_str().map(str::to_owned)))
            {
                if !taken.contains(&value) {
                    taken.push(value);
                }
            }
            dropped.entry(*file_index).or_default().insert(key.clone());
            totals["counts"]["cross_file_copies"] =
                json!(totals["counts"]["cross_file_copies"].as_i64().unwrap() + 1);
            if [
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            ]
            .iter()
            .any(|f| copy[*f] != kept[*f])
            {
                totals["anomalies"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!(format!(
                        "cross_file_conflict: {key} — {file} 的用量与 {} 不同，按后者计",
                        parsed[owner].file
                    )));
            }
        }
        if !replaces.is_empty() {
            kept["replaces"] = json!(replaces);
        }
        parsed[owner].records[index] = kept;
    }
    for (index, file) in parsed.iter_mut().enumerate() {
        if let Some(keys) = dropped.get(&index) {
            file.records.retain(|r| {
                !r["record_key"]
                    .as_str()
                    .is_some_and(|key| keys.contains(key))
            });
        }
    }
    elsewhere
}

pub fn sync(
    data: &Path,
    home: &Path,
    environment: &discovery::Environment,
    clock: Clock,
    zone: &LocalZone,
    cancel: &AtomicBool,
) -> Result<Value> {
    let started = Instant::now();
    let log = crate::diagnostics::RuntimeLog::new(data, Some(home));
    let _lock = SyncLock::acquire(data)?;
    let ledger = Ledger::open(&data.join("ledger.db"), clock)?;
    let run = ledger.begin_run()?;
    let result = (|| {
        let mut totals = json!({"attempted":0,"inserted":0,"updated":0,"unchanged":0,"rejected":0,"repriced":0,"counts":{"read_failed":0,"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0,"cross_file_copies":0},"anomalies":[]});
        let mut file_count = 0;
        for (source, files) in discovery::discover_with_env(home, environment)? {
            let discovered_files = files.clone();
            file_count += files.len();
            let mut parsed = Vec::new();
            for path in files {
                if cancel.load(Ordering::Acquire) {
                    return Err(Error("cancelled".into()));
                }
                let file = path.to_string_lossy().to_string();
                match adapters::parse(&source, &file, &path, zone) {
                    Ok((mut records, mut notes)) => {
                        records.retain(|r| {
                            if r.is_object() && !jscompat::truthy(&r["observed_at"]) {
                                notes["bad_times"] =
                                    json!(notes["bad_times"].as_i64().unwrap() + 1);
                                false
                            } else {
                                true
                            }
                        });
                        for (key, value) in notes.as_object().unwrap() {
                            totals["counts"][key] = json!(
                                totals["counts"][key].as_i64().unwrap_or(0)
                                    + value.as_i64().unwrap()
                            );
                        }
                        parsed.push(Parsed { file, records });
                    }
                    Err(error) => {
                        totals["counts"]["read_failed"] =
                            json!(totals["counts"]["read_failed"].as_i64().unwrap() + 1);
                        let note = format!("read_failed: {source} {file} — {error}");
                        log.write(
                            "WARN",
                            "sync",
                            &crate::diagnostics::safe_anomaly(&note, &discovered_files),
                        );
                        totals["anomalies"]
                            .as_array_mut()
                            .unwrap()
                            .push(json!(note));
                    }
                }
            }
            let previous_anomalies = totals["anomalies"].as_array().unwrap().len();
            let elsewhere = settle(&mut parsed, &mut totals);
            for note in totals["anomalies"].as_array().unwrap()[previous_anomalies..]
                .iter()
                .filter_map(Value::as_str)
            {
                log.write(
                    "WARN",
                    "sync",
                    &crate::diagnostics::safe_anomaly(note, &discovered_files),
                );
            }
            for file in parsed {
                let stats = ledger.batch_cancellable(
                    &file.records,
                    Some(&file.file),
                    super::ledger::Revisions {
                        usage: Some(adapters::parser_rev(&source)),
                        timing: adapters::timing_rev(&source),
                    },
                    elsewhere.get(&file.file).map(Vec::as_slice).unwrap_or(&[]),
                    pricing::cost_of,
                    || cancel.load(Ordering::Acquire),
                )?;
                for note in stats["anomalies"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    log.write(
                        "WARN",
                        "sync",
                        &crate::diagnostics::safe_anomaly(note, &discovered_files),
                    );
                }
                for field in ["attempted", "inserted", "updated", "unchanged", "rejected"] {
                    totals[field] =
                        json!(totals[field].as_i64().unwrap() + stats[field].as_i64().unwrap());
                }
                for (key, value) in stats["counts"].as_object().unwrap() {
                    totals["counts"][key] = json!(
                        totals["counts"][key].as_i64().unwrap_or(0) + value.as_i64().unwrap()
                    );
                }
                totals["anomalies"]
                    .as_array_mut()
                    .unwrap()
                    .extend(stats["anomalies"].as_array().unwrap().clone());
            }
        }
        if cancel.load(Ordering::Acquire) {
            return Err(Error("cancelled".into()));
        }
        totals["repriced"] =
            json!(ledger
                .reprice_cancellable(pricing::PRICE_VERSION, pricing::cost_of, || cancel
                    .load(Ordering::Acquire))?);
        ledger.finish_run(
            run,
            if totals["anomalies"].as_array().unwrap().is_empty() {
                "ok"
            } else {
                "completed_with_anomalies"
            },
            &totals,
        )?;
        totals["fileCount"] = json!(file_count);
        totals["durationMs"] = json!(started.elapsed().as_millis() as u64);
        log.write("INFO", "sync", &format!("end durationMs={} files={file_count} attempted={} inserted={} updated={} unchanged={} rejected={} counts={}", totals["durationMs"], totals["attempted"], totals["inserted"], totals["updated"], totals["unchanged"], totals["rejected"], totals["counts"]));
        Ok(totals)
    })();
    if let Err(error) = &result {
        let _ = ledger.fail_run(run, &error.to_string());
        log.write(
            if error.0 == "cancelled" {
                "INFO"
            } else {
                "ERROR"
            },
            "sync",
            &format!(
                "end status={} durationMs={}",
                crate::diagnostics::error_kind(&error.0),
                started.elapsed().as_millis()
            ),
        );
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ingestion_matches_node() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/parity");
        for (input, output) in [
            ("ingest-a.jsonl", ".claude/projects/a.jsonl"),
            ("ingest-b.jsonl", ".claude/projects/b.jsonl"),
            ("ingest-codex.jsonl", ".codex/sessions/rollout-test.jsonl"),
        ] {
            let file = home.join(output);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::copy(fixtures.join(input), file).unwrap();
        }
        let cancel = AtomicBool::new(false);
        for line in include_str!("../../tests/golden/ingest.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "run" {
                let mut result = sync(
                    &directory.path().join("data"),
                    &home,
                    &discovery::Environment::default(),
                    Clock::Fixed(1768478400000),
                    &LocalZone::Fixed(480),
                    &cancel,
                )
                .unwrap();
                result["durationMs"] = json!("<volatile>");
                assert_eq!(result, row["expected"]);
            }
        }
        let ledger = Ledger::open(
            &directory.path().join("data/ledger.db"),
            Clock::Fixed(1768478400000),
        )
        .unwrap();
        let mut actual = super::super::ledger::rows(
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
        let mut expected: Vec<Value> = include_str!("../../tests/golden/ingest.jsonl")
            .lines()
            .map(|s| serde_json::from_str::<Value>(s).unwrap())
            .filter(|r| r["type"] == "ledger_row")
            .map(|r| r["expected"].clone())
            .collect();
        for row in &mut expected {
            if row["source"] == "codex" {
                // Explicit Rust-only short-ID divergence; Node golden and all other fields stay pinned.
                assert_eq!(row["record_key"], "codex|codex-s|response-local");
                assert_eq!(row["parser_rev"], 4);
                let file = home.join(row["source_file"].as_str().unwrap());
                row["record_key"] = json!(format!(
                    "codex|codex-s|{}:2",
                    adapters::file_tag(file.to_str().unwrap())
                ));
                row["parser_rev"] = json!(5);
            }
        }
        assert_eq!(actual, expected);
    }
    #[test]
    fn corrupt_file_is_discarded_and_cancel_releases_lock() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let logs = home.join(".codex").join("sessions");
        std::fs::create_dir_all(&logs).unwrap();
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/parity");
        std::fs::copy(
            fixtures.join("zstd-garbage.bin"),
            logs.join("rollout-broken.jsonl.zst"),
        )
        .unwrap();
        let data = directory.path().join("data");
        let cancel = AtomicBool::new(false);
        let result = sync(
            &data,
            &home,
            &discovery::Environment::default(),
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(480),
            &cancel,
        )
        .unwrap();
        assert_eq!(result["counts"]["read_failed"], 1);
        assert_eq!(result["attempted"], 0);
        cancel.store(true, Ordering::Release);
        assert_eq!(
            sync(
                &data,
                &home,
                &discovery::Environment::default(),
                Clock::Fixed(1768478400000),
                &LocalZone::Fixed(480),
                &cancel
            )
            .unwrap_err()
            .0,
            "cancelled"
        );
        drop(SyncLock::acquire(&data).unwrap());
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::System).unwrap();
        assert_eq!(ledger.last_run().unwrap()["status"], "failed");
        assert_eq!(ledger.totals(&json!({})).unwrap()["record_count"], 0);
    }
}
