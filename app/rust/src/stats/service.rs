use super::{ledger::Ledger, pricing, Result};
use chrono::{DateTime, Duration};
use serde_json::{json, Value};
use std::borrow::Cow;
use std::collections::HashMap;
#[cfg(test)]
#[path = "service/d33_tests.rs"]
mod d33_tests;
#[cfg(test)]
#[path = "service/s5_tests.rs"]
mod s5_tests;
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
    add_exclusions(&mut result, params);
    if let Some(field @ ("project" | "model")) = params["missing"].as_str() {
        result["missing"] = json!(field);
    }
    Ok(result)
}

fn add_exclusions(filter: &mut Value, params: &Value) {
    if params["exclude_sources"]
        .as_array()
        .is_some_and(|ids| !ids.is_empty())
    {
        filter["exclude_sources"] = params["exclude_sources"].clone();
    }
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
    for key in ["request_count", "event_gross_tokens"] {
        if let Some(value) = value.get(key) {
            result[key] = value.clone();
        }
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
    // All usage and timing projections in this response share a committed snapshot.
    let _snapshot = ledger.db.unchecked_transaction()?;
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
    {
        let rows = ledger.cost_rows(&filter)?;
        let mut prices = HashMap::new();
        for row in &rows {
            let group = kinds.entry(group_key(row)).or_insert(([0; 4], false));
            if row["price_version"] != pricing::PRICE_VERSION {
                group.1 = true;
                continue;
            }
            let prices = &mut prices;
            let price = pricing::price_record_with(row, move || {
                let model = row["model"].as_str();
                Cow::Borrowed(
                    prices
                        .entry(model)
                        .or_insert_with(|| pricing::find_price(model)),
                )
            });
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
    }
    let raw = if by == "source_model" {
        ledger.grouped("source", "model", &filter)?
    } else {
        ledger.breakdown(by, &filter)?
    };
    let timings = ledger.timing_groups(by, &filter)?;
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
            result["timing"] = timings
                .groups
                .get(&kind_key)
                .cloned()
                .unwrap_or(json!({"request_count":0,"ttft":null,"speed":null}));
            if by == "source_model" {
                result["model_timing"] = timings
                    .models
                    .get(&key.to_string())
                    .cloned()
                    .unwrap_or(json!({"request_count":0,"ttft":null,"speed":null}));
            }
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
    let mut session_filter = filter.clone();
    for key in ["q", "sort", "dir"] {
        if let Some(value) = params.get(key) {
            session_filter[key] = value.clone();
        }
    }
    let cursor = super::jscompat::decode_cursor(params["cursor"].as_str());
    let (items, next) = ledger.sessions(params["limit"].as_i64(), cursor, &session_filter)?;
    let items: Vec<_> = items
        .iter()
        .map(|row| {
            let mut result = totals_shape(row);
            for key in [
                "session_id",
                "source",
                "project_key",
                "started_at",
                "last_seen_at",
                "has_cumulative",
            ] {
                result[key] = row[key].clone();
            }
            result["cumulative"] = totals_shape(&row["cumulative"]);
            result
        })
        .collect();
    Ok(
        json!({"items":items,"next_cursor":next.map(super::jscompat::encode_cursor),"snapshot":snapshot(ledger,&filter,tz)}),
    )
}

pub fn requests(ledger: &Ledger, params: &Value, offset: i32, tz: &str) -> Result<Value> {
    let session_scoped = !params["session_source"].is_null() || !params["session_id"].is_null();
    let mut filter = if session_scoped {
        let source = params["session_source"].as_str().unwrap_or("").trim();
        let session = params["session_id"].as_str().unwrap_or("").trim();
        if source.is_empty() || session.is_empty() {
            return Err(super::Error(
                "INVALID_PARAM: 需要同时给出 source 与 session_id".into(),
            ));
        }
        json!({"source":source,"session":session,"session_id":session,"offsetMinutes":offset})
    } else {
        let mut filter = filter(params, offset)?;
        filter["bucket"] = params["bucket"].clone();
        filter
    };
    add_exclusions(&mut filter, params);
    filter["include_summary"] = params["include_summary"].clone();
    request_page(ledger, params, &filter, tz)
}

fn request_page(ledger: &Ledger, params: &Value, filter: &Value, tz: &str) -> Result<Value> {
    let mut result = ledger.requests(
        filter,
        params["timed_only"].as_bool().unwrap_or(false),
        params["sort"].as_str().unwrap_or("time"),
        params["descending"].as_bool().unwrap_or(true),
        params["limit"].as_i64().unwrap_or(30),
        params["offset"].as_i64().unwrap_or(0),
    )?;
    for row in result["items"].as_array_mut().unwrap() {
        row["cost_usd"] = money(&row["cost_micros"]);
        row["price_state"] = pricing::classify_price(row["model"].as_str())["state"].clone();
    }
    result["snapshot"] = snapshot(ledger, filter, tz);
    Ok(result)
}

pub fn mini_usage(
    ledger: &Ledger,
    midnight: i64,
    now: i64,
    exclude_sources: &[String],
    tz: &str,
) -> Result<Value> {
    mini_usage_with(ledger, midnight, now, exclude_sources, tz, || {})
}

fn mini_usage_with(
    ledger: &Ledger,
    midnight: i64,
    now: i64,
    exclude_sources: &[String],
    tz: &str,
    after_totals: impl FnOnce(),
) -> Result<Value> {
    const HOUR: i64 = 3_600_000;
    let invalid = || super::Error("INVALID_RANGE: invalid mini window day".into());
    let hours_elapsed = now
        .checked_sub(midnight)
        .filter(|span| (0..26 * HOUR).contains(span))
        .ok_or_else(invalid)?
        / HOUR;
    let instant = |ms| {
        DateTime::from_timestamp_millis(ms)
            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
            .ok_or_else(invalid)
    };
    let today = json!({
        "observedMin": instant(midnight)?,
        "observedMax": instant(now)?,
        "exclude_sources": exclude_sources
    });
    let _snapshot = ledger.db.unchecked_transaction()?;
    let totals = ledger.totals(&today)?;
    let mut totals = {
        let mut shaped = totals_shape(&totals);
        shaped["cost_micros"] = totals["cost_micros"].clone();
        shaped
    };
    totals["record_count"] = json!(totals["record_count"].as_i64().unwrap_or_default());
    after_totals();

    let projects = mini_projects(ledger, &today)?;
    let mut hours = vec![0_i64; hours_elapsed as usize + 1];
    for row in ledger.mini_hours(&today, midnight)? {
        if let Some(total) = row["hour"]
            .as_u64()
            .and_then(|hour| hours.get_mut(hour as usize))
        {
            *total = row["gross_tokens"].as_i64().unwrap();
        }
    }
    let mut recent = today.clone();
    recent["observedMin"] = json!(instant(now - 300_000)?);
    let timings = ledger.timing_groups("source_model", &recent)?;
    let mut active = ledger.grouped("source", "model", &recent)?;
    active.sort_by(|a, b| {
        b["gross_tokens"]
            .as_i64()
            .cmp(&a["gross_tokens"].as_i64())
            .then_with(|| a["outer_key"].as_str().cmp(&b["outer_key"].as_str()))
            .then_with(|| a["inner_key"].as_str().cmp(&b["inner_key"].as_str()))
    });
    let models: Vec<Value> = active
        .into_iter()
        .filter(|row| row["gross_tokens"].as_i64().unwrap() > 0)
        .map(|row| {
            let model = &row["inner_key"];
            let mut group = totals_shape(&row);
            group["key"] = model.clone();
            group["model"] = model.clone();
            group["source"] = row["outer_key"].clone();
            group["model_timing"] = timings
                .models
                .get(&model.to_string())
                .cloned()
                .unwrap_or(Value::Null);
            group
        })
        .collect();
    let requests = request_page(ledger, &json!({"limit": 50}), &today, tz)?;
    Ok(
        json!({"totals":totals,"projects":projects,"hours":hours,"active_models":models,"requests":requests}),
    )
}

#[cfg(test)]
#[path = "service/mini_tests.rs"]
mod mini_tests;

fn mini_projects(ledger: &Ledger, filter: &Value) -> Result<Vec<Value>> {
    #[derive(Default)]
    struct Project {
        tokens: i64,
        cost: Option<i64>,
        tools: HashMap<String, i64>,
    }
    let mut projects = HashMap::<Option<String>, Project>::new();
    for row in ledger.grouped("project", "source", filter)? {
        let key = row["outer_key"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let project = projects.entry(key).or_default();
        let tokens = row["gross_tokens"].as_i64().unwrap();
        project.tokens += tokens;
        if let Some(cost) = row["cost_micros"].as_i64() {
            project.cost = Some(project.cost.unwrap_or(0) + cost);
        }
        *project
            .tools
            .entry(row["inner_key"].as_str().unwrap().to_owned())
            .or_default() += tokens;
    }
    let mut ordered: Vec<_> = projects.into_iter().collect();
    ordered
        .sort_by(|(key_a, a), (key_b, b)| b.tokens.cmp(&a.tokens).then_with(|| key_a.cmp(key_b)));
    Ok(ordered.into_iter().map(|(key, project)| {
        let mut tools: Vec<_> = project.tools.into_iter().collect();
        tools.sort_by(|(name_a, a), (name_b, b)| b.cmp(a).then_with(|| name_a.cmp(name_b)));
        let tools: Vec<_> = tools.into_iter().map(|(source, tokens)| json!({"source":source,"gross_tokens":tokens})).collect();
        json!({"key":key,"gross_tokens":project.tokens,"cost_micros":project.cost,"tools":tools})
    }).collect())
}

pub fn comparison(
    ledger: &Ledger,
    by: &str,
    current: &Value,
    previous: &Value,
    offset: i32,
) -> Result<Value> {
    comparison_with(ledger, by, current, previous, offset, || {})
}

fn comparison_with(
    ledger: &Ledger,
    by: &str,
    current: &Value,
    previous: &Value,
    offset: i32,
    after_current: impl FnOnce(),
) -> Result<Value> {
    let _snapshot = ledger.db.unchecked_transaction()?;
    let read = |params: &Value| -> Result<Value> {
        let filter = filter(params, offset)?;
        let format = |row: &Value| {
            let mut totals = totals_shape(row);
            totals["cost_micros"] = row["cost_micros"].clone();
            totals
        };
        let totals = format(&ledger.totals(&filter)?);
        let groups: Vec<_> = ledger
            .breakdown(by, &filter)?
            .iter()
            .map(|row| {
                let mut group = format(row);
                group["key"] = row["bucket"].clone();
                group
            })
            .collect();
        Ok(json!({"totals":totals,"groups":groups}))
    };
    let current = read(current)?;
    after_current();
    let previous = read(previous)?;
    Ok(json!({"by":by,"current":current,"previous":previous}))
}

pub fn session_detail(
    ledger: &Ledger,
    params: &Value,
    offset: i32,
    tz: &str,
) -> Result<Option<Value>> {
    let _snapshot = ledger.db.unchecked_transaction()?;
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
    if params["exclude_sources"]
        .as_array()
        .is_some_and(|ids| ids.iter().any(|id| id == source))
    {
        return Ok(None);
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
    let mut period_filter = filter(params, offset)?;
    period_filter["source"] = json!(source);
    period_filter["session"] = json!(session);
    let (period_items, _) = ledger.sessions(Some(1), 0, &period_filter)?;
    let period = period_items.first().map(totals_shape).unwrap_or_else(|| json!({
        "gross_tokens":0,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,
        "cache_write_tokens":0,"cost_usd":"0.000000","unpriced_records":0,
        "record_count":0,"event_gross_tokens":0,"request_count":if detail["kinds"]["event"] == 0 {Value::Null} else {json!(0)}
    }));
    let mut snapshot = snapshot(ledger, &json!({"source":source,"session_id":session}), tz);
    snapshot["granularity"] = json!(granularity);
    Ok(Some(
        json!({"timing":ledger.timing_summary(&period_filter)?,"period":period,"session":summary,"models":models,"timeline":timeline,"kinds":detail["kinds"],"granularity":granularity,"snapshot":snapshot}),
    ))
}

#[cfg(test)]
pub fn sources(
    ledger: &Ledger,
    now: &str,
    exists: impl Fn(&str) -> bool,
    tz: &str,
) -> Result<Value> {
    sources_for(ledger, now, exists, tz, false)
}

pub(crate) fn sources_for(
    ledger: &Ledger,
    now: &str,
    exists: impl Fn(&str) -> bool,
    tz: &str,
    include_sync_history: bool,
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
        let raw_en: Vec<_> = entries.iter().map(|row| row[3].clone()).collect();
        let notes: Vec<_> = entries.iter().map(|row| json!({"text":row[1],"impact":row[2],"text_en":row[4]})).collect();
        json!({"source":source,"evidence":evidence[source].as_str().unwrap_or("B"),"status":if records>0 {"ok"} else {"no_data"},"first_observed_at":row["first_observed_at"],"last_observed_at":row["last_observed_at"],"records":records,"record_mode":if cumulative==0 {"event"} else if cumulative==records {"cumulative"} else {"mixed"},"retention":{"reviewable":kept,"logs_gone":records-kept},"checks":checks[source],"limits":raw,"limits_en":raw_en,"notes":notes})
    }).collect();
    let run = ledger.last_run()?;
    let discovery_issues: Vec<_> = super::adapters::PARSER_REV
        .iter()
        .filter_map(|(source, _)| {
            super::discovery::DiscoveryIssue::from_run(source, &run["counts"])
        })
        .collect();
    let last_run = if run.is_null() {
        Value::Null
    } else {
        let mut value = run.clone();
        if !include_sync_history {
            value.as_object_mut().unwrap().remove("id");
        }
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
    let mut result = json!({"sources":sources,"last_run":last_run,"snapshot":snapshot});
    if include_sync_history {
        result["has_successful_sync"] = json!(ledger.has_successful_sync()?);
    }
    if !discovery_issues.is_empty() {
        result["discovery_issues"] = json!(discovery_issues);
    }
    Ok(result)
}

#[cfg(test)]
pub fn discovery(home: &std::path::Path, environment: &super::ingest::Environment) -> Value {
    discovery_summary(&super::discovery::discover_profiled(
        home,
        environment,
        None,
        false,
    ))
}

pub(crate) fn unrecorded_source_profiles() -> Result<HashMap<String, Value>> {
    let evidence: Value = serde_json::from_str(source_notes::EVIDENCE)?;
    let limits: Value = serde_json::from_str(source_notes::SOURCE_LIMITS)?;
    Ok(super::adapters::PARSER_REV.iter().map(|(source, _)| {
        let entries = limits[*source].as_array().map(Vec::as_slice).unwrap_or_default();
        let notes: Vec<_> = entries.iter().map(|row| json!({
            "text": row[1], "impact": row[2], "text_en": row[4]
        })).collect();
        let profile = json!({
            "source": source, "evidence": evidence[*source].as_str().unwrap_or("B"),
            "status": "no_data", "records": 0, "record_mode": "event",
            "retention": {"reviewable": 0, "logs_gone": 0},
            "checks": {"time_out_of_range": 0, "huge_requests": 0, "null_model": 0, "mixed_kind_sessions": 0},
            "limits": entries.iter().map(|entry| &entry[0]).collect::<Vec<_>>(),
            "limits_en": entries.iter().map(|entry| &entry[3]).collect::<Vec<_>>(),
            "notes": notes,
        });
        (source.to_string(), profile)
    }).collect())
}

pub(crate) fn discovery_summary(found: &super::discovery::Discovery) -> Value {
    let mut sources: Vec<_> = found
        .files
        .iter()
        .filter(|(_, files)| !files.is_empty())
        .map(|(source, files)| json!({"source":source,"files":files.len()}))
        .collect();
    sources.sort_by(|a, b| b["files"].as_u64().cmp(&a["files"].as_u64()));
    let mut result = json!({"sources":sources,"supported":super::adapters::PARSER_REV.len()});
    if !found.issues.is_empty() {
        result["discovery_issues"] = json!(found.issues);
    }
    result
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
        model["note_en"] = if local {
            json!("Local provider. Cost is zero.")
        } else {
            json!(pricing::english_note(class["id"].as_str()))
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
        assert_eq!(source["snapshot"]["known_sources"], 13);
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
            discovery(temp.path(), &environment),
            json!({"supported":super::super::adapters::PARSER_REV.len(),"sources":[{"source":"claude","files":1},{"source":"codex","files":1}]})
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
        for _ in 0..2 {
            ingest::reread(
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
                // Desktop-only timing fields are checked separately; retain Node's usage contract.
                for group in groups.as_array_mut().unwrap() {
                    group.as_object_mut().unwrap().remove("model_timing");
                    let timing = group.as_object_mut().unwrap().remove("timing").unwrap();
                    assert_eq!(
                        timing["request_count"],
                        group["request_count"].as_i64().unwrap_or(0)
                    );
                    assert!(timing["ttft"].is_null() && timing["speed"].is_null());
                }
                *groups = sorted(groups.clone());
            }
            if let Some(groups) = expected.get_mut("groups") {
                *groups = sorted(groups.clone());
            }
            assert_eq!(sorted(actual), sorted(expected), "{line}");
        }
    }
}
