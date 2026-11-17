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
                    Some(adapters::parser_rev(&source)),
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
                "WARN"
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
