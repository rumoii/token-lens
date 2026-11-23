pub use super::discovery::Environment;
#[cfg(test)]
#[path = "ingest_cache_tests.rs"]
mod cache_tests;
#[cfg(test)]
#[path = "ingest_oracle_tests.rs"]
mod oracle_tests;
#[cfg(test)]
use super::pricing;
use super::{
    adapters,
    clock::Clock,
    discovery,
    jscompat::{self, LocalZone},
    ledger::{CachedFile, FileOutput, Ledger, Revisions},
    lock::SyncLock,
    Error, Result,
};
#[path = "ingest_fingerprint.rs"]
mod fingerprint;

use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncPhases {
    discovery_ns: u64,
    #[serde(flatten)]
    adapter: adapters::ReadParsePhases,
    settle_ns: u64,
    cache_read_ns: u64,
    cache_write_ns: u64,
    parsed_files: usize,
    cached_files: usize,
    skipped_files: usize,
    write_ns: u64,
    write_transactions: usize,
    reprice_ns: u64,
    finish_run_ns: u64,
    total_ns: u64,
    files: usize,
    attempted: u64,
    sources: BTreeMap<String, SourcePhases>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SourcePhases {
    files: usize,
    discovery_ns: u64,
    total_ns: u64,
}

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
                        super::pricing::cost_of,
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

#[cfg(test)]
pub fn sync(
    data: &Path,
    home: &Path,
    environment: &discovery::Environment,
    clock: Clock,
    zone: &LocalZone,
    cancel: &AtomicBool,
) -> Result<Value> {
    sync_profiled(
        data,
        home,
        environment,
        clock,
        zone,
        cancel,
        SyncOptions::default(),
    )
    .map(|(result, _)| result)
}

#[cfg(test)]
pub fn reread(
    data: &Path,
    home: &Path,
    environment: &discovery::Environment,
    clock: Clock,
    zone: &LocalZone,
    cancel: &AtomicBool,
) -> Result<Value> {
    sync_profiled(
        data,
        home,
        environment,
        clock,
        zone,
        cancel,
        SyncOptions::new(true),
    )
    .map(|(result, _)| result)
}

pub(crate) enum Progress<'a> {
    Discovering {
        first_sync: bool,
    },
    Discovered {
        files: usize,
    },
    Reading {
        source: &'a str,
        index: usize,
        total: usize,
        source_files: usize,
    },
    FilesProcessed {
        count: usize,
        parsed: bool,
    },
    SourceFinished(&'a str),
}

pub(crate) fn sync_triggered(
    data: &Path,
    home: &Path,
    environment: &Environment,
    clock: Clock,
    cancel: &AtomicBool,
    trigger: &'static str,
    progress: &mut dyn FnMut(Progress<'_>),
) -> Result<Value> {
    let mut options = SyncOptions::new(trigger == "reread");
    options.trigger = Some(trigger);
    options.progress = Some(progress);
    sync_profiled(
        data,
        home,
        environment,
        clock,
        &LocalZone::System,
        cancel,
        options,
    )
    .map(|(result, _)| result)
}

// Rust-only entry point for the synthetic benchmark. Discovery uses no process overrides.
pub fn sync_benchmark(
    data: &Path,
    home: &Path,
    now_millis: i64,
    no_cache: bool,
) -> std::result::Result<(Value, Value), String> {
    let environment = Environment {
        platform: Environment::process().platform,
        ..Environment::default()
    };
    sync_profiled(
        data,
        home,
        &environment,
        Clock::Fixed(now_millis),
        &LocalZone::System,
        &AtomicBool::new(false),
        SyncOptions::new(no_cache),
    )
    .map_err(|error| error.to_string())
}

enum CacheUpdate {
    Keep,
    Invalidate,
    Store(CachedFile),
}

#[derive(Default)]
struct SyncOptions<'a> {
    no_cache: bool,
    trigger: Option<&'static str>,
    progress: Option<&'a mut dyn FnMut(Progress<'_>)>,
    #[cfg(test)]
    revisions: Option<Revisions>,
    #[cfg(test)]
    after_parse: Option<fn(&Path)>,
    #[cfg(test)]
    after_commit: Option<&'a dyn Fn()>,
}

impl SyncOptions<'_> {
    fn new(no_cache: bool) -> Self {
        Self {
            no_cache,
            trigger: None,
            progress: None,
            #[cfg(test)]
            revisions: None,
            #[cfg(test)]
            after_parse: None,
            #[cfg(test)]
            after_commit: None,
        }
    }
}

struct Input<'a> {
    path: &'a Path,
    file: String,
    fingerprint: Option<String>,
    hit: bool,
    had_cache: bool,
}

fn merge_counts(totals: &mut Value, counts: impl IntoIterator<Item = (impl AsRef<str>, i64)>) {
    for (key, value) in counts {
        let key = key.as_ref();
        totals["counts"][key] = json!(totals["counts"][key].as_i64().unwrap_or(0) + value);
    }
}

fn replacement_keys(records: &[Value]) -> Vec<String> {
    records
        .iter()
        .flat_map(|record| {
            let key = record["record_key"].as_str();
            record["replaces"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(move |target| !target.is_empty() && Some(*target) != key)
                .map(str::to_owned)
        })
        .collect()
}

fn sync_profiled(
    data: &Path,
    home: &Path,
    environment: &discovery::Environment,
    clock: Clock,
    zone: &LocalZone,
    cancel: &AtomicBool,
    mut options: SyncOptions<'_>,
) -> Result<(Value, Value)> {
    let started = Instant::now();
    let log = crate::diagnostics::RuntimeLog::new(data, Some(home));
    let _lock = SyncLock::acquire(data)?;
    let ledger = Ledger::open(&data.join("ledger.db"), clock)?;
    if let Some(progress) = options.progress.as_deref_mut() {
        progress(Progress::Discovering {
            first_sync: !ledger.has_successful_sync()?,
        });
    }
    let run = ledger.begin_run_triggered(options.trigger)?;
    let mut source_results = json!({});
    let result = (|| {
        let mut totals = json!({"attempted":0,"inserted":0,"updated":0,"unchanged":0,"rejected":0,"repriced":0,"counts":{"read_failed":0,"bad_lines":0,"bad_fields":0,"bad_times":0,"zero_usage":0,"cross_file_copies":0},"anomalies":[]});
        let mut phases = SyncPhases::default();
        let mut source_discovery = BTreeMap::new();
        let start = Instant::now();
        let discovered =
            discovery::discover_profiled(home, environment, Some(&mut source_discovery), false);
        phases.discovery_ns = start.elapsed().as_nanos() as u64;
        for issue in discovered.issues {
            let counts = issue
                .counts()
                .into_iter()
                .filter(|(_, count)| *count > 0)
                .map(|(kind, count)| (format!("discovery.{}.{kind}", issue.source), count as i64));
            merge_counts(&mut totals, counts);
            merge_counts(
                &mut totals,
                [("read_failed", issue.unreadable_entries as i64)],
            );
            if options.trigger.is_some() && issue.counts().into_iter().any(|(_, count)| count > 0) {
                source_results[format!("sync_source.{}", issue.source)] = json!(2);
            }
        }
        let total = discovered.files.len();
        if let Some(progress) = options.progress.as_deref_mut() {
            progress(Progress::Discovered {
                files: discovered.files.iter().map(|(_, files)| files.len()).sum(),
            });
        }
        for (index, (source, files)) in discovered.files.into_iter().enumerate() {
            if cancel.load(Ordering::Acquire) {
                return Err(Error("cancelled".into()));
            }
            let source_files = files.len();
            if let Some(progress) = options.progress.as_deref_mut() {
                progress(Progress::Reading {
                    source: &source,
                    index: index + 1,
                    total,
                    source_files,
                });
            }
            let source_started = Instant::now();
            let anomaly_count = totals["anomalies"].as_array().unwrap().len();
            phases.files += source_files;
            let mut process = || -> Result<()> {
                // SQLite adapters are always run. Cursor can have both SQLite and CSV inputs.
                let cache_source = !adapters::sqlite_only(&source);
                let revisions = Revisions {
                    usage: Some(adapters::parser_rev(&source)),
                    timing: adapters::timing_rev(&source),
                };
                #[cfg(test)]
                let revisions = options.revisions.unwrap_or(revisions);
                let start = Instant::now();
                let zone_before = cache_source
                    .then(|| fingerprint::zone_identity(zone))
                    .flatten();
                let mut previous = if cache_source {
                    ledger.cache_fingerprints(&source)?
                } else {
                    HashMap::new()
                };
                let mut candidates = Vec::with_capacity(source_files);
                for path in &files {
                    if cancel.load(Ordering::Acquire) {
                        return Err(Error("cancelled".into()));
                    }
                    let file = path.to_string_lossy().into_owned();
                    let cacheable = !adapters::uses_sqlite(&source, path);
                    let fingerprint = cacheable
                        .then(|| {
                            fingerprint::fingerprint(
                                &source,
                                path,
                                zone_before.as_deref(),
                                revisions,
                            )
                        })
                        .flatten();
                    let old = previous.remove(&file);
                    let hit = !options.no_cache && fingerprint.is_some() && fingerprint == old;
                    candidates.push(Input {
                        path,
                        file,
                        fingerprint,
                        hit,
                        had_cache: old.is_some(),
                    });
                }
                let skip = cache_source
                    && !options.no_cache
                    && previous.is_empty()
                    && candidates.iter().all(|input| input.hit)
                    && !ledger.cache_needs_replay(&source)?;
                phases.cache_read_ns += start.elapsed().as_nanos() as u64;
                if skip {
                    phases.skipped_files += source_files;
                    if source_files > 0 {
                        if let Some(progress) = options.progress.as_deref_mut() {
                            progress(Progress::FilesProcessed {
                                count: source_files,
                                parsed: false,
                            });
                        }
                    }
                    return Ok(());
                }

                let mut remove: Vec<String> = previous.into_keys().collect();
                let mut parsed = Vec::with_capacity(source_files);
                let mut updates = Vec::with_capacity(source_files);
                for Input {
                    path,
                    file,
                    fingerprint: before,
                    hit,
                    had_cache,
                } in candidates
                {
                    if cancel.load(Ordering::Acquire) {
                        return Err(Error("cancelled".into()));
                    }
                    if hit {
                        let start = Instant::now();
                        let output = ledger.cached_file(&source, &file)?;
                        phases.cache_read_ns += start.elapsed().as_nanos() as u64;
                        if let Some(output) = output {
                            merge_counts(&mut totals, output.notes);
                            phases.cached_files += 1;
                            parsed.push(Parsed {
                                file,
                                records: output.records,
                            });
                            updates.push(CacheUpdate::Keep);
                            if let Some(progress) = options.progress.as_deref_mut() {
                                progress(Progress::FilesProcessed {
                                    count: 1,
                                    parsed: false,
                                });
                            }
                            continue;
                        }
                    }
                    phases.parsed_files += 1;
                    let parsed_file = adapters::parse_profiled(
                        &source,
                        &file,
                        path,
                        zone,
                        environment.preview.then_some(home),
                        &mut phases.adapter,
                    );
                    if let Some(progress) = options.progress.as_deref_mut() {
                        progress(Progress::FilesProcessed {
                            count: 1,
                            parsed: true,
                        });
                    }
                    match parsed_file {
                        Ok((mut records, mut notes)) => {
                            #[cfg(test)]
                            if let Some(after_parse) = options.after_parse {
                                after_parse(path);
                            }
                            records.retain(|r| {
                                if r.is_object() && !jscompat::truthy(&r["observed_at"]) {
                                    notes["bad_times"] =
                                        json!(notes["bad_times"].as_i64().unwrap() + 1);
                                    false
                                } else {
                                    true
                                }
                            });
                            let mut notes: HashMap<String, i64> = serde_json::from_value(notes)?;
                            if let Some(rejected) = notes.remove("rejected_missing_time") {
                                for field in ["attempted", "rejected"] {
                                    totals[field] =
                                        json!(totals[field].as_i64().unwrap_or(0) + rejected);
                                }
                                let note = format!(
                                    "rejected: {source} — {rejected} 条用量缺少 observed_at（回复步骤、下一步和会话元数据均无可用时间）"
                                );
                                log.write("WARN", "sync", &note);
                                totals["anomalies"]
                                    .as_array_mut()
                                    .unwrap()
                                    .push(json!(note));
                            }
                            merge_counts(&mut totals, notes.iter().map(|(k, v)| (k, *v)));
                            let mut update = if had_cache {
                                CacheUpdate::Invalidate
                            } else {
                                CacheUpdate::Keep
                            };
                            if let Some(before) = before {
                                let start = Instant::now();
                                let zone_after = fingerprint::zone_identity(zone);
                                let after = fingerprint::fingerprint(
                                    &source,
                                    path,
                                    zone_after.as_deref(),
                                    revisions,
                                );
                                phases.cache_read_ns += start.elapsed().as_nanos() as u64;
                                if after.as_ref() == Some(&before) {
                                    let start = Instant::now();
                                    let replaces = replacement_keys(&records);
                                    let output = FileOutput { records, notes };
                                    let payload = serde_json::to_vec(&output)?;
                                    records = output.records;
                                    update = CacheUpdate::Store(CachedFile {
                                        fingerprint: before,
                                        payload,
                                        replaces,
                                    });
                                    phases.cache_write_ns += start.elapsed().as_nanos() as u64;
                                }
                            }
                            parsed.push(Parsed { file, records });
                            updates.push(update);
                        }
                        Err(error) => {
                            totals["counts"]["read_failed"] =
                                json!(totals["counts"]["read_failed"].as_i64().unwrap() + 1);
                            let note = format!("read_failed: {source} {file} — {error}");
                            log.write(
                                "WARN",
                                "sync",
                                &crate::diagnostics::safe_anomaly(&note, &files),
                            );
                            totals["anomalies"]
                                .as_array_mut()
                                .unwrap()
                                .push(json!(note));
                            if had_cache {
                                remove.push(file);
                            }
                        }
                    }
                }
                if cancel.load(Ordering::Acquire) {
                    return Err(Error("cancelled".into()));
                }
                let track_source = cache_source
                    && (source_files > 0
                        || !remove.is_empty()
                        || ledger.cache_needs_replay(&source)?);
                if track_source {
                    let start = Instant::now();
                    let remove: Vec<_> = remove.iter().map(String::as_str).collect();
                    ledger.cache_begin_source(&source, &remove)?;
                    phases.cache_write_ns += start.elapsed().as_nanos() as u64;
                }
                let previous_anomalies = totals["anomalies"].as_array().unwrap().len();
                let start = Instant::now();
                let elsewhere = settle(&mut parsed, &mut totals);
                phases.settle_ns += start.elapsed().as_nanos() as u64;
                for note in totals["anomalies"].as_array().unwrap()[previous_anomalies..]
                    .iter()
                    .filter_map(Value::as_str)
                {
                    log.write(
                        "WARN",
                        "sync",
                        &crate::diagnostics::safe_anomaly(note, &files),
                    );
                }
                for (file, update) in parsed.into_iter().zip(updates) {
                    let start = Instant::now();
                    let cache_before = phases.cache_write_ns;
                    let stats = ledger.batch_with_commit(
                        &file.records,
                        (
                            Some(&file.file),
                            revisions,
                            elsewhere.get(&file.file).map(Vec::as_slice).unwrap_or(&[]),
                        ),
                        |record| ledger.prices.cost_of(record),
                        || cancel.load(Ordering::Acquire),
                        |transaction| {
                            let cached = match &update {
                                CacheUpdate::Keep => return Ok(()),
                                CacheUpdate::Invalidate => None,
                                CacheUpdate::Store(cached) => Some(cached),
                            };
                            let start = Instant::now();
                            Ledger::write_ingest_file(transaction, &source, &file.file, cached)?;
                            phases.cache_write_ns += start.elapsed().as_nanos() as u64;
                            Ok(())
                        },
                    )?;
                    #[cfg(test)]
                    if let Some(after_commit) = options.after_commit {
                        after_commit();
                    }
                    phases.write_ns += (start.elapsed().as_nanos() as u64)
                        .saturating_sub(phases.cache_write_ns - cache_before);
                    phases.write_transactions += 1;
                    for note in stats["anomalies"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                    {
                        log.write(
                            "WARN",
                            "sync",
                            &crate::diagnostics::safe_anomaly(note, &files),
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
                if track_source {
                    let start = Instant::now();
                    ledger.cache_finish_source(&source)?;
                    phases.cache_write_ns += start.elapsed().as_nanos() as u64;
                }
                Ok(())
            };
            let processed = process();
            if options.trigger.is_some() && (source_files > 0 || processed.is_err()) {
                let had_anomaly = totals["anomalies"].as_array().unwrap().len() > anomaly_count;
                let result = &mut source_results[format!("sync_source.{source}")];
                *result = json!(if processed.is_err() {
                    3
                } else if had_anomaly || *result == 2 {
                    2
                } else {
                    1
                });
            }
            processed?;
            if source_files > 0 {
                if let Some(progress) = options.progress.as_deref_mut() {
                    progress(Progress::SourceFinished(&source));
                }
            }
            let discovery_ns = source_discovery.remove(&source).unwrap_or_default();
            phases.sources.insert(
                source,
                SourcePhases {
                    files: source_files,
                    discovery_ns,
                    total_ns: discovery_ns + source_started.elapsed().as_nanos() as u64,
                },
            );
        }
        if cancel.load(Ordering::Acquire) {
            return Err(Error("cancelled".into()));
        }
        let start = Instant::now();
        let repriced = ledger.reprice_cancellable(
            ledger.prices.version(),
            |record| ledger.prices.cost_of(record),
            || cancel.load(Ordering::Acquire),
        )?;
        phases.reprice_ns = start.elapsed().as_nanos() as u64;
        totals["repriced"] = json!(repriced);
        totals["parsedFiles"] = json!(phases.parsed_files);
        totals["cachedFiles"] = json!(phases.cached_files);
        totals["skippedFiles"] = json!(phases.skipped_files);
        let start = Instant::now();
        let counts = totals["counts"].clone();
        totals["counts"]
            .as_object_mut()
            .unwrap()
            .extend(source_results.as_object().unwrap().clone());
        ledger.finish_run(
            run,
            if totals["anomalies"].as_array().unwrap().is_empty() {
                "ok"
            } else {
                "completed_with_anomalies"
            },
            &totals,
        )?;
        totals["counts"] = counts;
        phases.finish_run_ns = start.elapsed().as_nanos() as u64;
        let file_count = phases.files;
        totals["fileCount"] = json!(file_count);
        let duration = started.elapsed();
        totals["durationMs"] = json!(duration.as_millis() as u64);
        phases.total_ns = duration.as_nanos() as u64;
        phases.attempted = totals["attempted"].as_u64().unwrap();
        log.write("INFO", "sync", &format!("end durationMs={} files={file_count} attempted={} inserted={} updated={} unchanged={} rejected={} counts={}", totals["durationMs"], totals["attempted"], totals["inserted"], totals["updated"], totals["unchanged"], totals["rejected"], totals["counts"]));
        let phases = json!(phases);
        log.write("INFO", "sync", &format!("phases {phases}"));
        Ok((totals, phases))
    })();
    if let Err(error) = &result {
        let _ = ledger.fail_run_with_results(
            run,
            &error.to_string(),
            options.trigger.map(|_| &source_results),
        );
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
    use crate::stats::native_golden_path;
    #[test]
    fn sync_reports_phases_and_counts_without_paths() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("private-synthetic-home");
        let data = directory.path().join("data");
        let log_file = home.join(".claude/projects/synthetic.jsonl");
        std::fs::create_dir_all(log_file.parent().unwrap()).unwrap();
        let text = r#"{"sessionId":"session","timestamp":"2026-01-15T01:00:00Z","message":{"id":"message","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":2}}}"#;
        std::fs::write(&log_file, text).unwrap();

        let result = sync(
            &data,
            &home,
            &discovery::Environment::default(),
            Clock::Fixed(1768478400000),
            &LocalZone::Fixed(0),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(crate::diagnostics::flush_runtime_log(
            std::time::Duration::from_secs(5)
        ));
        let log = std::fs::read_dir(data.join("logs"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.extension().is_some_and(|ext| ext == "log"))
            .map(|path| std::fs::read_to_string(path).unwrap())
            .expect("sync runtime log");
        let (end, phases) = log
            .lines()
            .zip(log.lines().skip(1))
            .find(|(end, phases)| end.contains("end durationMs=") && phases.contains("phases "))
            .expect("phase summary follows sync end");
        assert!(end.contains("attempted=1"));
        assert!(phases.contains("INFO"));
        assert!(!phases.contains("private-synthetic-home"));
        assert!(!phases.contains("synthetic.jsonl"));
        let phases: Value = serde_json::from_str(phases.split_once("phases ").unwrap().1).unwrap();
        assert_eq!(phases["files"], result["fileCount"]);
        assert_eq!(phases["attempted"], result["attempted"]);
        assert_eq!(phases["sources"]["claude"]["files"], 1);
        assert_eq!(phases["readFiles"], 1);
        assert_eq!(phases["readBytes"], text.len());
        assert_eq!(phases["parsedFiles"], 1);
        assert_eq!(phases["sqliteFiles"], 0);
        assert_eq!(phases["decompressedFiles"], 0);
        assert_eq!(phases["writeTransactions"], 1);
        let phase_ns: u64 = [
            "discoveryNs",
            "readNs",
            "decompressNs",
            "parseNs",
            "sqliteNs",
            "settleNs",
            "writeNs",
            "repriceNs",
            "finishRunNs",
        ]
        .iter()
        .map(|key| phases[key].as_u64().unwrap())
        .sum();
        assert!(phase_ns <= phases["totalNs"].as_u64().unwrap());
    }

    #[test]
    fn ingestion_matches_node() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/parity");
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
                let mut result = reread(
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
            super::super::update_golden_price_version(row);
            let source_file = native_golden_path(row["source_file"].as_str().unwrap());
            if row["source"] == "codex" {
                // Explicit Rust-only short-ID divergence; Node golden and all other fields stay pinned.
                assert_eq!(row["record_key"], "codex|codex-s|response-local");
                assert_eq!(row["parser_rev"], 4);
                // The short-ID fallback hashes the native absolute path of the fixture.
                let file = home.join(&source_file);
                row["record_key"] = json!(format!(
                    "codex|codex-s|{}:2",
                    adapters::file_tag(file.to_str().unwrap())
                ));
                row["parser_rev"] = json!(5);
            }
            row["source_file"] = json!(source_file);
        }
        assert_eq!(actual, expected);
    }
    #[test]
    fn corrupt_file_is_discarded_and_cancel_releases_lock() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let logs = home.join(".codex").join("sessions");
        std::fs::create_dir_all(&logs).unwrap();
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/parity");
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
