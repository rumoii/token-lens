use chrono::DateTime;
use rusqlite::{types::ValueRef, Connection, OpenFlags};
use rust_lib_token_lens::api::stats::{StatsClient, StatsFilter};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env, fs,
    io::Write,
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn hash(value: &Value) -> String {
    format!("{:x}", Sha256::digest(serde_json::to_vec(value).unwrap()))
}

fn tables(data: &Path) -> Result<Vec<Value>> {
    let db = Connection::open_with_flags(data.join("ledger.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut output = Vec::new();
    for table in [
        "usage_records",
        "legacy_records",
        "pricing_snapshot",
        "ingest_runs",
    ] {
        let order = match table {
            "usage_records" => "record_key",
            "pricing_snapshot" => "version",
            _ => "id",
        };
        let mut stmt = db.prepare(&format!("SELECT * FROM {table} ORDER BY {order}"))?;
        let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut cursor = stmt.query([])?;
        let mut rows = Vec::new();
        while let Some(row) = cursor.next()? {
            let mut value = Map::new();
            for (index, name) in names.iter().enumerate() {
                value.insert(
                    name.clone(),
                    match row.get_ref(index)? {
                        ValueRef::Null => Value::Null,
                        ValueRef::Integer(n) => json!(n),
                        ValueRef::Real(n) => json!(n),
                        ValueRef::Text(s) => json!(std::str::from_utf8(s)?),
                        ValueRef::Blob(b) => json!(b),
                    },
                );
            }
            rows.push(value);
        }
        let keys: BTreeMap<i64, Value> = rows
            .iter()
            .filter_map(|row| Some((row.get("id")?.as_i64()?, row.get("record_key")?.clone())))
            .collect();
        for mut row in rows {
            if table == "usage_records" {
                row.remove("id");
                if let Some(id) = row["superseded_by"].as_i64() {
                    row.insert(
                        "superseded_by".into(),
                        keys.get(&id).ok_or("invalid superseded key")?.clone(),
                    );
                }
            }
            if table == "ingest_runs" {
                if let Some(notes) = row["notes"].as_str() {
                    let notes: Vec<Value> = serde_json::from_str(notes)?;
                    row.insert(
                        "notes".into(),
                        json!(notes.iter().map(hash).collect::<Vec<_>>()),
                    );
                }
                if let Some(counts) = row["counts"].as_str() {
                    let parsed = serde_json::from_str(counts)?;
                    row.insert("counts".into(), parsed);
                }
            }
            if table == "pricing_snapshot" {
                let catalog =
                    serde_json::from_str(row["catalog_json"].as_str().ok_or("catalog missing")?)?;
                row.insert("catalog_json".into(), catalog);
            }
            output.push(json!({"type":"ledger_row","table":table,"expected":row}));
        }
    }
    Ok(output)
}

fn usage_digest(rows: &[Value]) -> String {
    let records: Vec<Value> = rows
        .iter()
        .filter(|row| row["table"] == "usage_records")
        .map(|row| {
            let mut record = row["expected"].as_object().unwrap().clone();
            record.remove("ingested_at");
            Value::Object(record)
        })
        .collect();
    hash(&json!(records))
}

// Undo only typed FFI additions to recover the existing service JSON shape.
fn service_shape(value: &mut Value) {
    if let Some(map) = value.as_object_mut() {
        if map.contains_key("cost_usd") {
            map.remove("cost_micros");
        }
        for key in [
            "input_micros",
            "output_micros",
            "cache_read_micros",
            "cache_write_micros",
        ] {
            map.remove(key);
        }
        for child in map.values_mut() {
            service_shape(child);
        }
    } else if let Some(array) = value.as_array_mut() {
        for child in array {
            service_shape(child);
        }
    }
}
fn query_shape(name: &str, mut value: Value) -> Value {
    service_shape(&mut value);
    let snapshot = value["snapshot"].as_object_mut().unwrap();
    for key in ["by", "granularity", "known_sources"] {
        if snapshot[key].is_null() {
            snapshot.remove(key);
        }
    }
    if name == "sources" {
        snapshot.insert("filters".into(), json!({}));
    } else {
        snapshot["filters"]
            .as_object_mut()
            .unwrap()
            .remove("session_id");
    }
    if name == "breakdown" {
        for group in value["groups"].as_array_mut().unwrap() {
            group.as_object_mut().unwrap().remove("source");
            group.as_object_mut().unwrap().remove("model");
        }
    }
    if name == "timeseries" {
        for point in value["points"].as_array_mut().unwrap() {
            point.as_object_mut().unwrap().remove("key");
        }
    }
    if name == "sources" && value["last_run"].is_object() {
        let notes = value["last_run"]["anomalies"].as_array().unwrap();
        value["last_run"]["anomalies"] = json!(notes.iter().map(hash).collect::<Vec<_>>());
    }
    value
}

fn set_home(home: &str, tz: &str, temp: &Path) -> Result<()> {
    // Called only by this single-threaded CLI before constructing any client.
    for key in [
        "DB_PATH",
        "TOKEN_LENS_DATA_DIR",
        "XDG_DATA_HOME",
        "OPENCODE_DB",
        "KILO_DB",
        "MIMOCODE_HOME",
        "MIMOCODE_DB",
        "MIMOCODE_DISABLE_CHANNEL_DB",
        "KIMI_SHARE_DIR",
        "OPENHANDS_CONVERSATIONS_DIR",
        "OPENHANDS_PERSISTENCE_DIR",
        "ZCODE_DATA_BASE_DIR",
        "ZCODE_SESSION_DB_PATH",
        "ZCODE_SESSION_DB",
        "MINIMAX_DATA_DIR",
        "GEMINI_HOME",
        "GOOSE_PATH_ROOT",
        "COPILOT_HOME",
        "OPENCLAW_HOME",
        "OPENCLAW_STATE_DIR",
    ] {
        env::remove_var(key);
    }
    for key in ["HOME", "USERPROFILE"] {
        env::set_var(key, home);
    }
    env::set_var("APPDATA", Path::new(home).join("AppData/Roaming"));
    env::set_var("LOCALAPPDATA", Path::new(home).join("AppData/Local"));
    env::set_var("TZ", tz);
    fs::create_dir_all(temp)?;
    for key in ["TEMP", "TMP", "TMPDIR"] {
        env::set_var(key, temp);
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 8 {
        return Err("expected --home --out --now --tz".into());
    }
    let mut options = BTreeMap::new();
    for pair in args.chunks(2) {
        if !["--home", "--out", "--now", "--tz"].contains(&pair[0].as_str())
            || options.insert(pair[0].clone(), pair[1].clone()).is_some()
        {
            return Err("invalid arguments".into());
        }
    }
    let home = PathBuf::from(options.get("--home").ok_or("home required")?);
    let out = PathBuf::from(options.get("--out").ok_or("out required")?);
    let now = DateTime::parse_from_rfc3339(options.get("--now").ok_or("now required")?)?;
    let tz = options.get("--tz").ok_or("tz required")?;
    if !home.is_absolute() || !out.is_absolute() || home.starts_with(&out) || out.starts_with(&home)
    {
        return Err("unsafe paths".into());
    }
    let original_home = env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .ok_or("system home missing")?;
    if home == PathBuf::from(&original_home)
        || out.starts_with(PathBuf::from(original_home).join(".token-lens"))
    {
        return Err("unsafe home/output".into());
    }
    // Old exports produce shared range/probe metadata; mismatches are fatal.
    let context: Value = serde_json::from_slice(&fs::read(out.join("context.json"))?)?;
    if context["home"].as_str() != home.to_str()
        || context["out"].as_str() != out.to_str()
        || context["tz"] != *tz
        || DateTime::parse_from_rfc3339(context["now"].as_str().ok_or("context now")?)? != now
    {
        return Err("context mismatch".into());
    }
    let data = out.join("new");
    if data.exists() || out.join("new.jsonl").exists() {
        return Err("new output already exists".into());
    }
    set_home(
        home.to_str().ok_or("home encoding")?,
        tz,
        &out.join("temp/new"),
    )?;
    let client = StatsClient::new_with_fixed_clock(
        data.to_string_lossy().into(),
        Some(home.to_string_lossy().into()),
        now.timestamp_millis(),
    )?;
    let mut results = Vec::new();
    let mut before = String::new();
    for index in 0..2 {
        results.push(client.sync()?);
        if index == 0 {
            before = usage_digest(&tables(&data)?);
        }
    }
    let ledger = tables(&data)?;
    let mut sources: Vec<Value> = context["probes"]
        .as_array()
        .ok_or("probes missing")?
        .iter()
        .map(|probe| probe["source"].clone())
        .collect();
    sources.sort_by_key(|v| v.as_str().unwrap_or("").to_owned());
    let mut rows = vec![
        json!({"type":"context","format":1,"complete":true,"sources":sources,"home":context["home"],"out":context["out"],"now":context["now"],"tz":tz}),
    ];
    rows.extend(ledger.clone());
    for (index, row) in ledger
        .iter()
        .filter(|r| r["table"] == "ingest_runs")
        .enumerate()
    {
        let mut expected = row["expected"].clone();
        expected["fileCount"] = json!(results[index].file_count);
        expected["anomalies"] = json!(results[index].anomalies.len());
        expected["durationMs"] = json!(results[index].duration_ms);
        rows.push(json!({"type":"run","index":index,"expected":expected}));
    }
    let offset = context["offset"].as_i64().ok_or("offset missing")? as i32;
    for range in context["ranges"].as_array().ok_or("ranges missing")? {
        let filter = StatsFilter {
            from: Some(range["from"].as_str().ok_or("from")?.into()),
            to: Some(range["to"].as_str().ok_or("to")?.into()),
            ..Default::default()
        };
        for (name, value) in [
            (
                "summary",
                serde_json::to_value(client.summary(filter.clone(), offset)?)?,
            ),
            (
                "timeseries",
                serde_json::to_value(client.timeseries("day".into(), filter.clone(), offset)?)?,
            ),
            (
                "matrix",
                serde_json::to_value(client.matrix(
                    "day".into(),
                    "model".into(),
                    filter.clone(),
                    offset,
                )?)?,
            ),
            (
                "sessions",
                serde_json::to_value(client.sessions(Some(50), None, filter.clone(), offset)?)?,
            ),
            ("sources", serde_json::to_value(client.sources()?)?),
        ] {
            rows.push(json!({"type":"query","range":range["range"],"fn":name,"expected":query_shape(name, value)}));
        }
        for by in ["source", "model", "project"] {
            let value =
                serde_json::to_value(client.breakdown(by.into(), filter.clone(), offset)?)?;
            rows.push(json!({"type":"query","range":range["range"],"fn":"breakdown","by":by,"expected":query_shape("breakdown", value)}));
        }
    }
    rows.push(json!({"type":"query","range":"idempotence","fn":"usage_digest","expected":{"before":before,"after":usage_digest(&ledger)}}));
    for probe in context["probes"].as_array().ok_or("probes missing")? {
        let source = probe["source"].as_str().ok_or("source")?;
        if !source.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err("invalid source".into());
        }
        let probe_home = PathBuf::from(probe["home"].as_str().ok_or("probe home")?);
        if !probe_home.starts_with(out.join("probe-inputs")) {
            return Err("probe escaped output".into());
        }
        set_home(
            probe_home.to_str().ok_or("probe encoding")?,
            tz,
            &out.join("temp/new"),
        )?;
        let probe_data = out.join("probe-ledgers").join(source);
        let probe_client = StatsClient::new_with_fixed_clock(
            probe_data.to_string_lossy().into(),
            Some(probe_home.to_string_lossy().into()),
            now.timestamp_millis(),
        )?;
        let result = probe_client.sync()?;
        if json!(result.file_count) != probe["fileCount"] {
            return Err("source probe discovery mismatch".into());
        }
        rows.push(json!({"type":"source_notes","source":source,"expected":{"bad_fields":result.counts.bad_fields,"bad_times":result.counts.bad_times}}));
    }
    let mut file = fs::File::create(out.join("new.jsonl"))?;
    for row in rows {
        serde_json::to_writer(&mut file, &row)?;
        writeln!(file)?;
    }
    println!("new: two production collections and export complete");
    Ok(())
}

fn main() {
    if run().is_err() {
        eprintln!("new: failed; source content suppressed");
        std::process::exit(2);
    }
}
