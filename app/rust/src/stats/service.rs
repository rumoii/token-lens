use super::{ledger::Ledger, pricing, Result};
use chrono::{DateTime, Duration};
use serde_json::{json, Value};
use std::collections::HashMap;

fn filter(params: &Value, offset: i32) -> Value {
    let mut result = json!({"from":params["from"].as_str().unwrap_or(""),"to":params["to"].as_str().unwrap_or(""),"offsetMinutes":offset});
    for name in ["source", "model", "project"] {
        result[name] = params[name]
            .as_str()
            .filter(|s| !s.is_empty())
            .map_or(Value::Null, |s| json!(s));
    }
    result
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
    let filter = filter(params, offset);
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
    let filter = filter(params, offset);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::{clock::Clock, ingest, jscompat::LocalZone};
    use std::{path::Path, sync::atomic::AtomicBool};
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
