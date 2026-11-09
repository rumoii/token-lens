use super::{ledger::Ledger, pricing, Result};
use chrono::{DateTime, Duration};
use serde_json::{json, Value};
use std::collections::HashMap;
#[cfg(test)]
#[path = "service/d33_tests.rs"]
mod d33_tests;
#[path = "source_notes.rs"]
mod source_notes;

fn filter(params: &Value, offset: i32) -> Result<Value> {
    validate_range(params)?;
    let mut result = json!({"from":params["from"].as_str().unwrap_or(""),"to":params["to"].as_str().unwrap_or(""),"offsetMinutes":offset});
    for name in ["source", "model", "project"] {
        result[name] = params[name]
            .as_str()
            .filter(|s| !s.is_empty())
            .map_or(Value::Null, |s| json!(s));
    }
    Ok(result)
}

pub fn validate_range(params: &Value) -> Result<()> {
    let from = params["from"].as_str().unwrap_or("");
    let to = params["to"].as_str().unwrap_or("");
    if !from.is_empty() && !to.is_empty() && from > to {
        return Err(super::Error("INVALID_RANGE: from 晚于 to".into()));
    }
    Ok(())
}
fn money(value: &Value) -> Value {
    json!(pricing::format_micros(value.as_i64(), 6))
}
fn totals_shape(value: &Value) -> Value {
    let mut result = json!({});
    for name in [
        "gross_tokens",
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "unpriced_records",
        "record_count",
    ] {
        result[name] = value[name].clone();
    }
    result["cost_usd"] = money(&value["cost_micros"]);
    result
}
fn snapshot(ledger: &Ledger, filter: &Value, tz: &str) -> Value {
    json!({"generated_at":ledger.clock.iso(),"price_version":pricing::PRICE_VERSION,"tz":tz,"filters":filter})
}
fn display_parts(parts: &[i64; 4]) -> Value {
    let strings = pricing::allocate_display(parts, parts.iter().sum(), 6);
    json!({"input":strings[0],"output":strings[1],"cache_read":strings[2],"cache_write":strings[3]})
}

pub fn summary(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    let filter = filter(params, offset)?;
    let totals = ledger.totals(&filter)?;
    let activity = ledger.activity(&filter)?;
    let local = DateTime::from_timestamp_millis(ledger.clock.millis()).unwrap()
        + Duration::minutes(offset as i64);
    let mut rolling = json!({});
    for (key, days) in [("last_7d", 6), ("last_30d", 29)] {
        let mut window = filter.clone();
        window["from"] = json!((local - Duration::days(days))
            .format("%Y-%m-%d")
            .to_string());
        let row = ledger.totals(&window)?;
        rolling[key] =
            json!({"gross_tokens":row["gross_tokens"],"cost_usd":money(&row["cost_micros"])});
    }
    let denominator = activity["input_tokens"].as_i64().unwrap()
        + activity["cache_read_tokens"].as_i64().unwrap();
    let ratio = if denominator > 0 {
        let value = super::jscompat::ratio_four_places(
            activity["cache_read_tokens"].as_i64().unwrap() as f64 / denominator as f64,
        );
        if value.fract() == 0.0 {
            json!(value as i64)
        } else {
            json!(value)
        }
    } else {
        Value::Null
    };
    let span = activity["first_seen"]
        .as_str()
        .zip(activity["last_seen"].as_str())
        .and_then(|(a, b)| {
            Some(
                (DateTime::parse_from_rfc3339(b).ok()?.timestamp_millis()
                    - DateTime::parse_from_rfc3339(a).ok()?.timestamp_millis())
                .max(0),
            )
        });
    Ok(
        json!({"totals":totals_shape(&totals),"activity":{"sessions":activity["sessions"],"turns":activity["turns"],"cache_hit_ratio":ratio,"first_seen":activity["first_seen"],"last_seen":activity["last_seen"],"active_span_ms":span},"rolling":rolling,"snapshot":snapshot(ledger,&filter,tz)}),
    )
}

pub fn breakdown(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    let by = params["by"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("model");
    let filter = filter(params, offset)?;
    let mut kinds: HashMap<String, ([i64; 4], bool)> = HashMap::new();
    let group_key = |row: &Value| {
        if by == "source_model" {
            json!([row["source"], row["model"]]).to_string()
        } else {
            row[if by == "project" { "project_key" } else { by }].to_string()
        }
    };
    for row in ledger.cost_rows(&filter)? {
        let group = kinds.entry(group_key(&row)).or_insert(([0; 4], false));
        if row["price_version"] != pricing::PRICE_VERSION {
            group.1 = true;
            continue;
        }
        let price = pricing::price_record(&row);
        if price["cost_micros"].is_null() || price["cost_micros"] != row["cost_micros"] {
            group.1 = true;
            continue;
        }
        for (index, key) in ["input", "output", "cache_read", "cache_write"]
            .iter()
            .enumerate()
        {
            group.0[index] += price["parts"][*key].as_i64().unwrap();
        }
    }
    let raw = if by == "source_model" {
        ledger.grouped("source", "model", &filter)?
    } else {
        ledger.breakdown(by, &filter)?
    };
    let groups: Vec<Value> = raw
        .iter()
        .map(|row| {
            let key = if by == "source_model" {
                &row["inner_key"]
            } else {
                &row["bucket"]
            };
            let mut result = totals_shape(row);
            result["key"] = key.clone();
            if by == "source_model" {
                result["source"] = row["outer_key"].clone();
                result["model"] = key.clone();
            }
            result["price_state"] = if by == "model" || by == "source_model" {
                let price = pricing::find_price(key.as_str());
                json!(price["tier"].as_str().unwrap_or("unknown"))
            } else {
                Value::Null
            };
            let kind_key = if by == "source_model" {
                json!([row["outer_key"], key]).to_string()
            } else {
                key.to_string()
            };
            result["cost_by_kind"] = kinds
                .get(&kind_key)
                .filter(|(parts, invalid)| {
                    !*invalid && Some(parts.iter().sum::<i64>()) == row["cost_micros"].as_i64()
                })
                .map_or(Value::Null, |(parts, _)| display_parts(parts));
            result
        })
        .collect();
    Ok(
        json!({"by":by,"groups":groups,"totals":totals_shape(&ledger.totals(&filter)?),"snapshot":snapshot(ledger,&filter,tz)}),
    )
}

fn time_service(
    ledger: &Ledger,
    params: &Value,
    offset: i32,
    tz: &str,
    grouped: bool,
) -> Result<Value> {
    let filter = filter(params, offset)?;
    let granularity = params["granularity"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("day");
    let by = params["by"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("model");
    let raw = if grouped {
        ledger.timeseries_grouped(granularity, by, &filter)?
    } else {
        ledger.timeseries(granularity, &filter)?
    };
    let key = if grouped { "rows" } else { "points" };
    let points: Vec<_> = raw[key]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let mut value = totals_shape(row);
            value["bucket"] = row["bucket"].clone();
            if grouped {
                value["key"] = row["group"].clone();
            }
            value
        })
        .collect();
    let unallocated = &raw["unallocated"];
    let unallocated = if unallocated.is_null() {
        Value::Null
    } else {
        json!({"gross_tokens":unallocated["gross_tokens"],"cost_usd":money(&unallocated["cost_micros"]),"record_count":unallocated["record_count"],"reason":unallocated["reason"]})
    };
    let mut value = json!({"granularity":granularity,"unallocated":unallocated,"snapshot":snapshot(ledger,&filter,tz)});
    value[key] = json!(points);
    if grouped {
        value["by"] = json!(by);
        value["snapshot"]["granularity"] = json!(granularity);
        value["snapshot"]["by"] = json!(by);
    }
    Ok(value)
}

pub fn timeseries(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    time_service(ledger, params, offset, tz, false)
}

pub fn matrix(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    time_service(ledger, params, offset, tz, true)
}

pub fn sessions(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    let filter = filter(params, offset)?;
    let cursor = super::jscompat::decode_cursor(params["cursor"].as_str());
    let (items, next) = ledger.sessions(params["limit"].as_i64(), cursor, &filter)?;
    let items: Vec<_> = items.iter().map(|row| json!({"session_id":row["session_id"],"source":row["source"],"project_key":row["project_key"],"started_at":row["started_at"],"last_seen_at":row["last_seen_at"],"gross_tokens":row["gross_tokens"],"cost_usd":money(&row["cost_micros"]),"record_count":row["record_count"]})).collect();
    Ok(
        json!({"items":items,"next_cursor":next.map(super::jscompat::encode_cursor),"snapshot":snapshot(ledger,&filter,tz)}),
    )
}

pub fn session_detail(
    ledger: &Ledger,
    params: &Value,
    offset: i32,
    tz: &str,
) -> Result<Option<Value>> {
    validate_range(params)?;
    let source = params["source"].as_str().unwrap_or("").trim();
    let session = params["session_id"].as_str().unwrap_or("").trim();
    if source.is_empty() || session.is_empty() {
        return Err(super::Error(
            "INVALID_PARAM: 需要同时给出 source 与 session_id".into(),
        ));
    }
    let granularity = params["granularity"].as_str().unwrap_or("");
    if !matches!(granularity, "hour" | "day") {
        return Err(super::Error(
            "INVALID_PARAM: granularity 必须为 hour 或 day".into(),
        ));
    }
    let Some(detail) = ledger.session_detail(source, session, granularity, offset)? else {
        return Ok(None);
    };
    let mut summary = totals_shape(&detail["summary"]);
    for key in [
        "source",
        "session_id",
        "project_key",
        "started_at",
        "last_seen_at",
    ] {
        summary[key] = detail["summary"][key].clone();
    }
    let models: Vec<_> = detail["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let mut value = totals_shape(row);
            value["model"] = row["model"].clone();
            value["price_state"] = pricing::classify_price(row["model"].as_str())["state"].clone();
            value
        })
        .collect();
    let timeline: Vec<_> = detail["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let mut value = totals_shape(row);
            value["bucket"] = row["bucket"].clone();
            value
        })
        .collect();
    let mut snapshot = snapshot(ledger, &json!({"source":source,"session_id":session}), tz);
    snapshot["granularity"] = json!(granularity);
    Ok(Some(
        json!({"session":summary,"models":models,"timeline":timeline,"kinds":detail["kinds"],"granularity":granularity,"snapshot":snapshot}),
    ))
}

pub fn sources(
    ledger: &Ledger,
    now: &str,
    exists: impl Fn(&str) -> bool,
    tz: &str,
) -> Result<Value> {
    let evidence: Value = serde_json::from_str(source_notes::EVIDENCE)?;
    let limits: Value = serde_json::from_str(source_notes::SOURCE_LIMITS)?;
    let checks = ledger.source_checks(now)?;
    let mut reviewable = HashMap::<String, i64>::new();
    for row in ledger.source_files()? {
        if row["source_file"].as_str().is_some_and(&exists) {
            *reviewable
                .entry(row["source"].as_str().unwrap().into())
                .or_default() += row["records"].as_i64().unwrap();
        }
    }
    let sources: Vec<_> = ledger.source_status()?.iter().map(|row| {
        let source = row["source"].as_str().unwrap();
        let records = row["records"].as_i64().unwrap();
        let cumulative = row["cumulative_records"].as_i64().unwrap();
        let kept = reviewable.get(source).copied().unwrap_or(0);
        let entries = limits[source].as_array().cloned().unwrap_or_default();
        let raw: Vec<_> = entries.iter().map(|row| row[0].clone()).collect();
        let notes: Vec<_> = entries.iter().map(|row| json!({"text":row[1],"impact":row[2]})).collect();
        json!({"source":source,"evidence":evidence[source].as_str().unwrap_or("B"),"status":if records>0 {"ok"} else {"no_data"},"first_observed_at":row["first_observed_at"],"last_observed_at":row["last_observed_at"],"records":records,"record_mode":if cumulative==0 {"event"} else if cumulative==records {"cumulative"} else {"mixed"},"retention":{"reviewable":kept,"logs_gone":records-kept},"checks":checks[source],"limits":raw,"notes":notes})
    }).collect();
    let run = ledger.last_run()?;
    let last_run = if run.is_null() {
        Value::Null
    } else {
        let mut value = run.clone();
        value.as_object_mut().unwrap().remove("id");
        for field in ["started_at", "finished_at"] {
            value[field] = json!(run[field]
                .as_i64()
                .filter(|n| *n != 0)
                .and_then(|n| DateTime::from_timestamp(n, 0))
                .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)));
        }
        let anomalies = run["anomalies"].as_array().unwrap();
        value["anomaly_count"] = json!(anomalies.len());
        value["anomalies"] = json!(anomalies.iter().take(5).cloned().collect::<Vec<_>>());
        value
    };
    let mut snapshot = snapshot(ledger, &json!({}), tz);
    snapshot["known_sources"] = json!(evidence.as_object().unwrap().len());
    Ok(json!({"sources":sources,"last_run":last_run,"snapshot":snapshot}))
}

pub fn discovery(
    home: &std::path::Path,
    environment: &super::ingest::Environment,
) -> Result<Value> {
    let found = super::discovery::discover_with_env(home, environment)?;
    let mut sources: Vec<_> = found
        .iter()
        .filter(|(_, files)| !files.is_empty())
        .map(|(source, files)| json!({"source":source,"files":files.len()}))
        .collect();
    sources.sort_by(|a, b| b["files"].as_u64().cmp(&a["files"].as_u64()));
    Ok(json!({"sources":sources,"supported":super::adapters::PARSER_REV.len()}))
}

fn prices_of(value: &Value) -> Value {
    json!({"input":value["input"],"output":value["output"],"cache_read":value["cacheRead"],"cache_write_5m":value["cacheWrite"],"cache_write_1h":value["cacheWrite1h"]})
}

pub fn pricing(ledger: &Ledger, tz: &str) -> Result<Value> {
    let mut models: Vec<Value> = Vec::new();
    for row in ledger.model_price_marks()? {
        let index = models.iter().position(|model| model["model"] == row["model"]).unwrap_or_else(|| {
            models.push(json!({"model":row["model"],"records":row["model_records"],"price_marks":{},"local_providers":{},"local_records":0})); models.len()-1
        });
        let model = &mut models[index];
        let mark = row["mark"].as_str().unwrap();
        let count = row["records"].as_i64().unwrap();
        model["price_marks"][mark] =
            json!(model["price_marks"][mark].as_i64().unwrap_or(0) + count);
        if let Some(local) = pricing::local_provider(row["provider"].as_str()) {
            model["local_providers"][&local] =
                json!(model["local_providers"][&local].as_i64().unwrap_or(0) + count);
            model["local_records"] = json!(model["local_records"].as_i64().unwrap() + count);
        }
    }
    let mut counts = json!({"verified":0,"aggregate":0,"unknown":0,"local":0});
    for model in &mut models {
        let local = model["local_records"] == model["records"];
        let class = pricing::classify_price(model["model"].as_str());
        let price = if local {
            Value::Null
        } else {
            pricing::find_price(model["model"].as_str())
        };
        model["state"] = if local {
            json!("local")
        } else {
            class["state"].clone()
        };
        model["billing"] = if local {
            json!("local")
        } else {
            class["billing"].clone()
        };
        model["source_url"] = if local {
            Value::Null
        } else {
            class["sourceUrl"].clone()
        };
        model["note"] = if local {
            json!("本地提供方，金额按 0 计。")
        } else {
            class["note"].clone()
        };
        model["prices"] = if local {
            prices_of(&json!({"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"cacheWrite1h":0}))
        } else if price.is_null() {
            Value::Null
        } else {
            prices_of(&price["perMTok"])
        };
        model["tiers"] = price["tiers"]
            .as_array()
            .map(|tiers| {
                json!(tiers
                    .iter()
                    .map(|tier| json!({"above":tier["above"],"prices":prices_of(&tier["perMTok"])}))
                    .collect::<Vec<_>>())
            })
            .unwrap_or(Value::Null);
        let tod = &price["timeOfDay"];
        model["time_of_day"] = if tod.is_null() {
            Value::Null
        } else {
            let mut holidays = tod["holidays"].as_array().cloned().unwrap_or_default();
            holidays.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
            json!({"utc_offset_minutes":tod["utcOffsetMinutes"],"peak":tod["peak"],"off_peak_prices":prices_of(&tod["offPeak"]),"holidays_count":holidays.len(),"holidays_through":holidays.last()})
        };
        let state = model["state"].as_str().unwrap();
        counts[state] = json!(counts[state].as_i64().unwrap() + 1);
    }
    Ok(
        json!({"price_version":pricing::PRICE_VERSION,"verified_at":if models.is_empty(){None}else{Some(ledger.clock.iso()[..10].to_owned())},"currency":"USD","provisional":counts["aggregate"].as_i64().unwrap()>0,"models":models,"counts":counts,"snapshot":snapshot(ledger,&json!({}),tz)}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::{clock::Clock, ingest, jscompat::LocalZone};
    use std::{path::Path, sync::atomic::AtomicBool};
    #[test]
    fn d33_common_invalid_range_and_detail_params() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        let bad = json!({"from":"2026-02-01","to":"2026-01-01"});
        for result in [
            summary(&ledger, &bad, 0, "UTC"),
            breakdown(&ledger, &bad, 0, "UTC"),
            timeseries(&ledger, &bad, 0, "UTC"),
            matrix(&ledger, &bad, 0, "UTC"),
            sessions(&ledger, &bad, 0, "UTC"),
        ] {
            assert_eq!(
                result.unwrap_err().to_string(),
                "INVALID_RANGE: from 晚于 to"
            );
        }
        assert_eq!(
            session_detail(
                &ledger,
                &json!({"source":" ","session_id":"s","granularity":"hour"}),
                0,
                "UTC"
            )
            .unwrap_err()
            .to_string(),
            "INVALID_PARAM: 需要同时给出 source 与 session_id"
        );
        assert!(session_detail(
            &ledger,
            &json!({"source":"s","session_id":"s","granularity":"month"}),
            0,
            "UTC"
        )
        .unwrap_err()
        .to_string()
        .starts_with("INVALID_PARAM:"));
        assert!(session_detail(
            &ledger,
            &json!({"source":"s","session_id":"missing","granularity":"hour"}),
            0,
            "UTC"
        )
        .unwrap()
        .is_none());
    }
    #[test]
    fn d33_services_preserve_shapes_and_injected_sources() {
        let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
        ledger.batch(&[json!({"record_key":"s","source":"claude","session_id":"id","model":"unknown","provider":"OLLAMA","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":7,"source_file":"synthetic"})],Some("synthetic"),None,&[],pricing::cost_of).unwrap();
        assert_eq!(
            timeseries(&ledger, &json!({}), 0, "UTC").unwrap()["points"][0]["cost_usd"],
            "0.000000"
        );
        assert_eq!(
            matrix(&ledger, &json!({}), 0, "UTC").unwrap()["rows"][0]["key"],
            "unknown"
        );
        assert_eq!(
            sessions(&ledger, &json!({"limit":0}), 0, "UTC").unwrap()["items"][0]["session_id"],
            "id"
        );
        let detail = session_detail(
            &ledger,
            &json!({"source":"claude","session_id":"id","granularity":"hour"}),
            0,
            "UTC",
        )
        .unwrap()
        .unwrap();
        assert_eq!(detail["session"]["output_tokens"], Value::Null);
        assert_eq!(
            detail["snapshot"]["filters"],
            json!({"source":"claude","session_id":"id"})
        );
        let source = sources(&ledger, "2026-01-15T12:00:00.000Z", |_| true, "UTC").unwrap();
        assert_eq!(source["sources"][0]["retention"]["reviewable"], 1);
        assert_eq!(source["snapshot"]["known_sources"], 12);
        let prices = pricing(&ledger, "UTC").unwrap();
        assert_eq!(prices["models"][0]["local_providers"]["ollama"], 1);
        assert_eq!(prices["models"][0]["state"], "local");
        assert_eq!(prices["models"][0]["prices"]["input"], 0);
        let temp = tempfile::tempdir().unwrap();
        let environment = super::super::ingest::Environment::default();
        let found = super::super::discovery::discover_with_env(temp.path(), &environment).unwrap();
        assert_eq!(
            found
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>(),
            super::super::adapters::PARSER_REV
                .iter()
                .map(|(name, _)| *name)
                .collect::<Vec<_>>()
        );
        for file in [
            ".claude/projects/a.jsonl",
            ".codex/sessions/rollout-a.jsonl",
        ] {
            let path = temp.path().join(file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "").unwrap();
        }
        assert_eq!(
            discovery(temp.path(), &environment).unwrap(),
            json!({"supported":27,"sources":[{"source":"claude","files":1},{"source":"codex","files":1}]})
        );
    }
    fn sorted(value: Value) -> Value {
        if let Value::Array(mut array) = value {
            array.sort_by_key(|v| {
                json!([
                    v["record_key"],
                    v["bucket"],
                    v["key"],
                    v["outer_key"],
                    v["inner_key"],
                    v["source"],
                    v["model"],
                    v["project_key"],
                    v["observed_at"],
                    v["ended_at"],
                    v
                ])
                .to_string()
            });
            json!(array)
        } else {
            value
        }
    }
    #[test]
    fn cache_ratio_rounding_matches_node() {
        for line in include_str!("../../tests/golden/query-boundaries.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] != "query" {
                continue;
            }
            let ledger = Ledger::open(Path::new(":memory:"), Clock::Fixed(1768478400000)).unwrap();
            ledger
                .batch(&[row["record"].clone()], None, None, &[], pricing::cost_of)
                .unwrap();
            assert_eq!(
                summary(&ledger, &json!({}), 480, "Asia/Shanghai").unwrap(),
                row["expected"]
            );
        }
    }
    #[test]
    fn queries_and_services_match_node() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let data = directory.path().join("data");
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
        for _ in 0..2 {
            ingest::sync(
                &data,
                &home,
                &super::super::discovery::Environment::default(),
                Clock::Fixed(1768478400000),
                &LocalZone::Fixed(480),
                &AtomicBool::new(false),
            )
            .unwrap();
        }
        let ledger = Ledger::open(&data.join("ledger.db"), Clock::Fixed(1768478400000)).unwrap();
        for line in include_str!("../../tests/golden/ingest.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            let name = row["fn"].as_str().unwrap_or("");
            let args = &row["args"];
            let actual = match name {
                "lastRun" => ledger.last_run().unwrap(),
                "summary" => summary(
                    &ledger,
                    &row["params"],
                    row["offsetMinutes"].as_i64().unwrap() as i32,
                    row["params"]["tz"].as_str().unwrap(),
                )
                .unwrap(),
                "breakdown" => breakdown(
                    &ledger,
                    &row["params"],
                    row["offsetMinutes"].as_i64().unwrap() as i32,
                    row["params"]["tz"].as_str().unwrap(),
                )
                .unwrap(),
                "tamperedBreakdown" => {
                    ledger
                        .db
                        .execute_batch(row["sql"].as_str().unwrap())
                        .unwrap();
                    let result = breakdown(&ledger, &row["params"], 480, "Asia/Shanghai").unwrap();
                    ledger.db.execute_batch("UPDATE usage_records SET cost_micros=cost_micros-1 WHERE record_key='claude|owner'; UPDATE usage_records SET price_version='7a41a11013b21c6b' WHERE record_key='claude|older';").unwrap();
                    result
                }
                "read.totals" => ledger.totals(&args[0]).unwrap(),
                "read.activity" => ledger.activity(&args[0]).unwrap(),
                "read.breakdown" => json!(ledger
                    .breakdown(args[0].as_str().unwrap(), &args[1])
                    .unwrap()),
                "read.grouped" => json!(ledger
                    .grouped(
                        args[0].as_str().unwrap(),
                        args[1].as_str().unwrap(),
                        &args[2]
                    )
                    .unwrap()),
                "read.costRows" => json!(ledger.cost_rows(&args[0]).unwrap()),
                _ => continue,
            };
            let mut actual = actual;
            let mut expected = row["expected"].clone();
            if let Some(groups) = actual.get_mut("groups") {
                *groups = sorted(groups.clone());
            }
            if let Some(groups) = expected.get_mut("groups") {
                *groups = sorted(groups.clone());
            }
            assert_eq!(sorted(actual), sorted(expected), "{line}");
        }
    }
}
