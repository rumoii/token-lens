//! `sync_bench generate --home <TEMP/fixture> [--scale N] [--seed S]`
//! `sync_bench run --home <TEMP/fixture> --out <TEMP/results> [--runs N]`
//! `sync_bench once --home <TEMP/fixture> --data <TEMP/ledger> --out <TEMP/results>`

#[path = "support/system_home.rs"]
mod system_home;

use rusqlite::{params, types::ValueRef, Connection, OpenFlags};
use rust_lib_token_lens::{
    api::stats::{StatsClient, StatsFilter, StatsRequestQuery},
    sync_benchmark,
};
use ruzstd::encoding::{compress_to_vec, CompressionLevel};
use serde::Serialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env, fs,
    io::{BufWriter, ErrorKind, Write},
    path::{Component, Path, PathBuf},
    time::Instant,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const CLOCK_MS: i64 = 1768478400000;
const DAY_MS: i64 = 86_400_000;

fn path_key(path: &Path) -> String {
    let path = path.to_string_lossy();
    if cfg!(windows) {
        path.replace('/', "\\")
            .trim_start_matches("\\\\?\\")
            .to_lowercase()
    } else {
        path.into_owned()
    }
}

fn within(root: &Path, path: &Path) -> bool {
    let root = path_key(root);
    let path = path_key(path);
    path == root
        || path
            .strip_prefix(root.trim_end_matches(std::path::MAIN_SEPARATOR))
            .is_some_and(|suffix| suffix.starts_with(std::path::MAIN_SEPARATOR))
}

fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn checked_temp_path(path: &Path) -> Result<()> {
    if !path.is_absolute() || path.components().any(|part| part == Component::ParentDir) {
        return Err("benchmark paths must be absolute and contain no '..' components".into());
    }
    let mut homes = vec![system_home::system_home()?];
    homes.extend(
        ["HOME", "USERPROFILE"]
            .iter()
            .filter_map(env::var_os)
            .map(PathBuf::from),
    );
    if homes.iter().any(|home| {
        path_key(path) == path_key(home)
            || within(&home.join(".token-lens"), path)
            || within(&home.join("AppData/Roaming/Token Lens"), path)
    }) || env::var_os("APPDATA")
        .is_some_and(|root| within(&PathBuf::from(root).join("Token Lens"), path))
    {
        return Err("benchmark path points to a protected home or ledger".into());
    }

    let temp = env::temp_dir();
    let resolved_temp = temp.canonicalize()?;
    let root = [&temp, &resolved_temp]
        .into_iter()
        .find(|root| within(root, path) && path_key(root) != path_key(path))
        .ok_or("benchmark paths must be inside the system TEMP directory")?;
    for ancestor in path
        .ancestors()
        .take_while(|ancestor| path_key(ancestor) != path_key(root))
    {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) if metadata.is_dir() && !linked(&metadata) => {}
            Ok(_) => return Err("benchmark directory paths must be ordinary directories".into()),
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn empty_output(path: &Path) -> Result<()> {
    checked_temp_path(path)?;
    match fs::read_dir(path) {
        Ok(mut entries) => match entries.next() {
            Some(_) => Err("output directory must be empty".into()),
            None => Ok(()),
        },
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(fs::create_dir_all(path)?),
        Err(error) => Err(error.into()),
    }
}

fn check_input_tree(dir: &Path) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let metadata = fs::symlink_metadata(&path)?;
        if linked(&metadata) || !(metadata.is_dir() || metadata.is_file()) {
            return Err("benchmark input must contain only ordinary directories and files".into());
        }
        if metadata.is_dir() {
            check_input_tree(&path)?;
        }
    }
    Ok(())
}

fn next_number(state: &mut u64) -> u64 {
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
    *state >> 32
}

fn timestamp(file: usize, row: usize) -> i64 {
    CLOCK_MS - (1 + (file % 14) as i64) * DAY_MS + row as i64 * 10_000
}

fn append_line(writer: &mut impl Write, value: Value) -> Result<()> {
    serde_json::to_writer(&mut *writer, &value)?;
    writer.write_all(b"\n")?;
    Ok(())
}

fn generate(home: &Path, scale: usize, mut seed: u64) -> Result<()> {
    if scale == 0 || scale.checked_mul(60_030).is_none() {
        return Err("scale must be positive and fit in the record count".into());
    }
    empty_output(home)?;
    let claude = home.join(".claude/projects");
    let codex = home.join(".codex/sessions");
    let qwen = home.join(".qwen/usage");
    let opencode = home.join(".local/share/opencode");
    for dir in [&claude, &codex, &qwen, &opencode] {
        fs::create_dir_all(dir)?;
    }

    for file in 0..1240 * scale {
        let session = format!("claude-{file:06}");
        let project = format!("/synthetic/project-{:02}", file % 24);
        let path = claude.join(format!("{session}.jsonl"));
        let mut writer = BufWriter::new(fs::File::create(path)?);
        let records = if file % 10 == 0 { 220 } else { 22 };
        for row in 0..records {
            let time = timestamp(file, row);
            let input = 200 + next_number(&mut seed) % 8000;
            let output = 20 + next_number(&mut seed) % 500;
            let request = format!("request-{row:04}");
            append_line(
                &mut writer,
                json!({
                    "type":"api-request","id":request,"sessionId":session,"timestamp":time-1200
                }),
            )?;
            append_line(
                &mut writer,
                json!({
                    "type":"assistant","sessionId":session,"cwd":project,"timestamp":time,
                    "requestRef":request,"message":{
                    "id":format!("msg_{file:06}_{row:04}"),"model":"claude-opus-5-5","stop_reason":"end_turn",
                        "usage":{"input_tokens":input,"output_tokens":output,"cache_read_input_tokens":input/3}
                    }
                }),
            )?;
        }
        writer.flush()?;
    }

    for file in 0..119 * scale {
        let session = format!("codex-{file:06}");
        let project = format!("/synthetic/project-{:02}", file % 24);
        let mut bytes = Vec::new();
        append_line(
            &mut bytes,
            json!({
                "type":"session_meta","payload":{
                    "session_id":session,"cwd":project,"model_provider":"openai","model":"gpt-5.5"
                }
            }),
        )?;
        for row in 0..42 {
            let input = 300 + next_number(&mut seed) % 7000;
            let output = 10 + next_number(&mut seed) % 400;
            append_line(
                &mut bytes,
                json!({
                    "type":"token_usage_record","timestamp":timestamp(file,row),"payload":{
                        "response_id":format!("resp_synthetic_{file:06}_{row:06}"),
                        "usage":{"input_tokens":input,"cached_input_tokens":input/4,"output_tokens":output}
                    }
                }),
            )?;
        }
        let path = codex.join(format!("rollout-{session}.jsonl"));
        if file % 15 == 0 {
            let compressed = compress_to_vec(bytes.as_slice(), CompressionLevel::Fastest);
            fs::write(path.with_extension("jsonl.zst"), compressed)?;
        } else {
            fs::write(path, bytes)?;
        }
    }

    for file in 0..40 * scale {
        let session = format!("qwen-{file:06}");
        let mut writer = BufWriter::new(fs::File::create(
            qwen.join(format!("token-usage-{session}.jsonl")),
        )?);
        for row in 0..50 {
            let input = 100 + next_number(&mut seed) % 3000;
            let output = 10 + next_number(&mut seed) % 200;
            append_line(
                &mut writer,
                json!({
                    "sessionId":session,"id":format!("qwen-request-{row:04}"),
                    "timestamp":timestamp(file,row),"model":"qwen3-coder","authType":"qwen-oauth",
                    "inputTokens":input,"outputTokens":output,"cachedTokens":input/5,"apiDurationMs":800+output
                }),
            )?;
        }
        writer.flush()?;
    }

    let mut db = Connection::open(opencode.join("opencode.db"))?;
    let transaction = db.transaction()?;
    transaction.execute_batch(
        "CREATE TABLE message(id,session_id,time_updated,time_created,data);
         CREATE TABLE session(id,directory);
         INSERT INTO session VALUES('opencode-session','/synthetic/project-opencode');",
    )?;
    {
        let mut insert =
            transaction.prepare("INSERT INTO message VALUES(?1,'opencode-session',?2,?2,?3)")?;
        for row in 0..1200 * scale {
            let input = 200 + next_number(&mut seed) % 5000;
            let output = 20 + next_number(&mut seed) % 300;
            let value = json!({
                "type":"assistant","model":{"id":"claude-opus-5-5","providerID":"anthropic"},
                "tokens":{"input":input,"output":output,"cache":{"read":input/3,"write":20}}
            });
            let time = timestamp(row / 100, row % 100);
            insert.execute(params![
                format!("opencode-request-{row:08}"),
                time,
                value.to_string()
            ])?;
        }
    }
    transaction.commit()?;
    Ok(())
}

fn measure_query<T: Serialize>(
    timings: &mut BTreeMap<&'static str, u64>,
    outputs: &mut Map<String, Value>,
    name: &'static str,
    call: impl FnOnce() -> std::result::Result<T, String>,
) -> Result<()> {
    let started = Instant::now();
    let result = call()?;
    timings.insert(name, started.elapsed().as_nanos() as u64);
    outputs.insert(name.into(), serde_json::to_value(result)?);
    Ok(())
}

struct QueryMeasurements {
    timings: BTreeMap<&'static str, u64>,
    results: Map<String, Value>,
}

fn measure_queries(client: &StatsClient) -> Result<QueryMeasurements> {
    let mut timings = BTreeMap::new();
    let mut results = Map::new();
    let filter = StatsFilter::default();
    measure_query(&mut timings, &mut results, "summary", || {
        client.summary(filter.clone(), 0)
    })?;
    measure_query(&mut timings, &mut results, "timeseriesDay", || {
        client.timeseries("day".into(), filter.clone(), 0)
    })?;
    for (name, by) in [
        ("breakdownSource", "source"),
        ("breakdownSourceModel", "source_model"),
        ("breakdownProject", "project"),
    ] {
        measure_query(&mut timings, &mut results, name, || {
            client.breakdown(by.into(), filter.clone(), 0)
        })?;
    }
    measure_query(&mut timings, &mut results, "matrixDaySource", || {
        client.matrix("day".into(), "source".into(), filter.clone(), 0)
    })?;
    measure_query(&mut timings, &mut results, "sessions", || {
        client.sessions(None, None, filter.clone(), 0)
    })?;
    measure_query(&mut timings, &mut results, "requestsFirstPage", || {
        client.requests(
            filter,
            StatsRequestQuery {
                source: None,
                session_id: None,
                bucket: None,
                timed_only: false,
                sort: "time".into(),
                descending: true,
                limit: 30,
                offset: 0,
                include_summary: true,
            },
            0,
        )
    })?;
    Ok(QueryMeasurements { timings, results })
}

fn snapshot_rows(
    db: &Connection,
    sql: &str,
    args: impl rusqlite::Params,
    home: &Path,
) -> Result<Vec<Value>> {
    let mut statement = db.prepare(sql)?;
    let columns = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut rows = statement.query(args)?;
    let mut result = Vec::new();
    while let Some(row) = rows.next()? {
        let mut object = Map::new();
        for (index, column) in columns.iter().enumerate() {
            let value = match row.get_ref(index)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(number) => json!(number),
                ValueRef::Real(number) => json!(number),
                ValueRef::Text(bytes) if column == "source_file" => {
                    let path = Path::new(std::str::from_utf8(bytes)?);
                    json!(path
                        .strip_prefix(home)?
                        .to_str()
                        .ok_or("invalid source path")?
                        .replace('\\', "/"))
                }
                ValueRef::Text(bytes) => json!(std::str::from_utf8(bytes)?),
                ValueRef::Blob(_) => return Err("unexpected blob in ledger snapshot".into()),
            };
            object.insert(column.clone(), value);
        }
        object.remove("id");
        object.remove("ingested_at");
        if let Some(key) = object.remove("superseding_key") {
            object.insert("superseded_by".into(), key);
        }
        result.push(Value::Object(object));
    }
    Ok(result)
}

fn snapshot(
    db: &Connection,
    home: &Path,
    queries: Map<String, Value>,
    include_inactive: bool,
) -> Result<Value> {
    let usage = snapshot_rows(
        db,
        "SELECT u.*,
        (SELECT s.record_key FROM usage_records s WHERE s.id=u.superseded_by) AS superseding_key
        FROM usage_records u WHERE ?1 OR u.active=1 ORDER BY u.record_key",
        [include_inactive],
        home,
    )?;
    let timings = snapshot_rows(
        db,
        "SELECT * FROM usage_timings ORDER BY record_key",
        [],
        home,
    )?;
    let (cost_micros, priced, active): (Option<i64>, i64, i64) = db.query_row(
        "SELECT SUM(cost_micros), COUNT(cost_micros), COUNT(*) FROM usage_records WHERE active=1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    Ok(json!({
        "version":1,
        "usage":usage,
        "usageTimings":timings,
        "money":{"costMicros":cost_micros,"pricedRecords":priced,"unpricedRecords":active-priced},
        "queries":queries
    }))
}

fn run(home: &Path, out: &Path, runs: usize, existing_data: Option<&Path>) -> Result<()> {
    checked_temp_path(home)?;
    checked_temp_path(out)?;
    let home = home.canonicalize()?;
    let out = std::path::absolute(out)?;
    if within(&home, &out) || within(&out, &home) {
        return Err("benchmark home and output must not overlap".into());
    }
    let data = if let Some(data) = existing_data {
        checked_temp_path(data)?;
        let data = std::path::absolute(data)?;
        if [&home, &out]
            .into_iter()
            .any(|root| within(root, &data) || within(&data, root))
        {
            return Err("benchmark home, data and output must not overlap".into());
        }
        if data.try_exists()? {
            check_input_tree(&data)?;
        }
        data
    } else {
        out.join("data")
    };
    check_input_tree(&home)?;
    empty_output(&out)?;
    let mut results = Vec::new();
    let mut baseline = None;
    let mut records_by_source = BTreeMap::new();
    let mut hashes_match = true;
    for index in 1..=runs {
        let (sync, phases) = sync_benchmark(&data, &home, CLOCK_MS)?;
        let client = StatsClient::new_with_fixed_clock(
            data.to_str().ok_or("invalid data path")?.into(),
            Some(home.to_str().ok_or("invalid home path")?.into()),
            CLOCK_MS,
        )?;
        let queries = measure_queries(&client)?;
        let db =
            Connection::open_with_flags(data.join("ledger.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let snapshot = snapshot(&db, &home, queries.results, existing_data.is_some())?;
        if index == 1 {
            for row in snapshot["usage"].as_array().unwrap() {
                *records_by_source
                    .entry(row["source"].as_str().unwrap().to_owned())
                    .or_insert(0_u64) += 1;
            }
        }
        let bytes = serde_json::to_vec(&snapshot)?;
        let hash = format!("{:x}", Sha256::digest(&bytes));
        hashes_match &= baseline.get_or_insert_with(|| hash.clone()) == &hash;
        let file = format!("snapshot-{index}.json");
        fs::write(out.join(&file), bytes)?;
        results.push(json!({
            "run":index,"sync":sync,"phases":phases,"queryNs":queries.timings,
            "snapshot":file,"snapshotSha256":hash,
        }));
    }
    let report = json!({
        "version":1,"clockMs":CLOCK_MS,"recordsBySource":records_by_source,
        "hashesMatch":hashes_match,"runs":results
    });
    fs::write(
        out.join("benchmark.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!(
        "{}",
        json!({
            "runs":runs,"recordsBySource":records_by_source,
            "totalNs":results.iter().map(|row| &row["phases"]["totalNs"]).collect::<Vec<_>>(),
            "snapshotSha256":baseline,"hashesMatch":hashes_match
        })
    );
    if !hashes_match {
        return Err("normalized snapshots differ across runs".into());
    }
    Ok(())
}

fn execute(mut args: impl Iterator<Item = String>) -> Result<()> {
    let command = args.next().ok_or("expected generate, run or once")?;
    let allowed: &[&str] = match command.as_str() {
        "generate" => &["--home", "--scale", "--seed"],
        "run" => &["--home", "--out", "--runs"],
        "once" => &["--home", "--out", "--data"],
        _ => return Err("expected generate, run or once".into()),
    };
    let mut flags = BTreeMap::new();
    while let Some(flag) = args.next() {
        if !allowed.contains(&flag.as_str()) || flags.contains_key(&flag) {
            return Err(format!("unexpected or duplicate option: {flag}").into());
        }
        let value = args
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        flags.insert(flag, value);
    }
    let home = Path::new(flags.get("--home").ok_or("--home is required")?);
    if command == "generate" {
        let scale = flags.get("--scale").map_or(Ok(1), |value| value.parse())?;
        let seed = flags.get("--seed").map_or(Ok(42), |value| value.parse())?;
        generate(home, scale, seed)
    } else {
        let out = Path::new(flags.get("--out").ok_or("--out is required")?);
        if command == "once" {
            let data = Path::new(flags.get("--data").ok_or("--data is required")?);
            return run(home, out, 1, Some(data));
        }
        let runs = flags.get("--runs").map_or(Ok(3), |value| value.parse())?;
        if runs == 0 {
            return Err("--runs must be positive".into());
        }
        run(home, out, runs, None)
    }
}

fn main() {
    // Fix the query zone before creating the first client in this standalone process.
    env::set_var("TZ", "UTC");
    if let Err(error) = execute(env::args().skip(1)) {
        eprintln!("sync_bench: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        fn collect(root: &Path, dir: &Path, output: &mut BTreeMap<PathBuf, Vec<u8>>) {
            for entry in fs::read_dir(dir).unwrap() {
                let entry = entry.unwrap();
                let path = entry.path();
                if entry.file_type().unwrap().is_dir() {
                    collect(root, &path, output);
                } else {
                    output.insert(
                        path.strip_prefix(root).unwrap().into(),
                        fs::read(path).unwrap(),
                    );
                }
            }
        }
        let mut output = BTreeMap::new();
        collect(root, root, &mut output);
        output
    }

    #[test]
    fn same_seed_generates_identical_files() {
        let root = tempfile::tempdir().unwrap();
        let first = root.path().join("first");
        let second = root.path().join("second");
        generate(&first, 1, 42).unwrap();
        generate(&second, 1, 42).unwrap();
        let expected = files(&first);
        assert_eq!(expected.len(), 1400);
        assert_eq!(expected, files(&second));
    }

    #[test]
    fn generated_claude_messages_survive_cross_file_settlement() {
        let root = tempfile::tempdir().unwrap();
        let generated = root.path().join("generated");
        generate(&generated, 1, 42).unwrap();
        let sample = root.path().join("sample");
        let relative = Path::new(".claude/projects");
        fs::create_dir_all(sample.join(relative)).unwrap();
        for name in ["claude-000000.jsonl", "claude-000001.jsonl"] {
            let file = relative.join(name);
            fs::copy(generated.join(&file), sample.join(&file)).unwrap();
        }
        let (totals, _) = sync_benchmark(&root.path().join("data"), &sample, CLOCK_MS).unwrap();
        assert_eq!(totals["counts"]["cross_file_copies"], 0);
        assert_eq!(totals["inserted"], 242);
    }

    #[test]
    fn single_sync_can_reopen_an_existing_ledger() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let logs = home.join(".qwen/usage");
        fs::create_dir_all(&logs).unwrap();
        let path = logs.join("token-usage-qwen-test.jsonl");
        let record = |tokens| {
            json!({
                "id":"request","sessionId":"qwen-test","timestamp":CLOCK_MS - DAY_MS,
                "inputTokens":tokens,"outputTokens":10,
            })
        };
        let data = root.path().join("data");
        for (index, tokens, expected) in [(1, 20, "inserted"), (2, 40, "updated")] {
            fs::write(&path, record(tokens).to_string()).unwrap();
            let output = root.path().join(index.to_string());
            execute(
                [
                    "once",
                    "--home",
                    home.to_str().unwrap(),
                    "--data",
                    data.to_str().unwrap(),
                    "--out",
                    output.to_str().unwrap(),
                ]
                .into_iter()
                .map(str::to_owned),
            )
            .unwrap();
            let result: Value =
                serde_json::from_slice(&fs::read(output.join("benchmark.json")).unwrap()).unwrap();
            assert_eq!(result["runs"][0]["sync"][expected], 1);
        }
    }

    #[test]
    fn generator_rejects_real_home_and_nonempty_output() {
        let home = system_home::system_home().unwrap();
        assert!(generate(&home, 1, 42)
            .unwrap_err()
            .to_string()
            .contains("protected"));
        let dir = tempfile::tempdir().unwrap();
        let sentinel = dir.path().join("keep.txt");
        fs::write(&sentinel, b"keep").unwrap();
        assert!(generate(dir.path(), 1, 42)
            .unwrap_err()
            .to_string()
            .contains("empty"));
        assert_eq!(fs::read(sentinel).unwrap(), b"keep");
    }
}
