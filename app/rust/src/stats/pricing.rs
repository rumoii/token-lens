use chrono::{DateTime, Datelike, Utc};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::sync::OnceLock;

pub const PRICE_VERSION: &str = "c9fe1db9270c1778";

fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| serde_json::from_str(include_str!("pricing-catalog.json")).unwrap())
}

fn canonical(value: &Value) -> String {
    match value {
        Value::Array(a) => format!(
            "[{}]",
            a.iter().map(canonical).collect::<Vec<_>>().join(",")
        ),
        Value::Object(object) => {
            let keys: &[&str] = if object.contains_key("utcOffsetMinutes") {
                &["utcOffsetMinutes", "peak", "offPeak", "holidays"]
            } else if object.contains_key("days") {
                &["days", "from", "to"]
            } else if object.contains_key("above") {
                &["above", "perMTok"]
            } else {
                &["input", "output", "cacheRead", "cacheWrite", "cacheWrite1h"]
            };
            format!(
                "{{{}}}",
                keys.iter()
                    .filter_map(|k| object.get(*k).map(|v| format!("\"{k}\":{}", canonical(v))))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
        Value::Number(n) => super::jscompat::number_string(n.as_f64().unwrap()),
        _ => value.to_string(),
    }
}

pub fn catalog_version() -> String {
    let entries: Vec<_> = catalog()["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            json!([
                e["id"],
                e["perMTok"],
                e["verifiedAt"],
                e["tier"],
                e["tiers"],
                e["timeOfDay"],
                e["billing"]
            ])
        })
        .collect();
    format!(
        "{:x}",
        Sha256::digest(canonical(&json!([entries, catalog()["localProviders"]])).as_bytes())
    )[..16]
        .into()
}

fn numeric_separators(name: &str, from: char, to: char) -> String {
    let chars: Vec<_> = name.chars().collect();
    let mut output = String::new();
    let mut i = 0;
    while i < chars.len() {
        if i + 2 < chars.len()
            && chars[i].is_ascii_digit()
            && chars[i + 1] == from
            && chars[i + 2].is_ascii_digit()
        {
            output.push(chars[i]);
            output.push(to);
            output.push(chars[i + 2]);
            i += 3;
        } else {
            output.push(chars[i]);
            i += 1;
        }
    }
    output
}

fn candidates(raw: &str) -> Vec<String> {
    let mut name = raw.trim().to_lowercase();
    let mut without_parentheses = String::new();
    while let Some(start) = name.find('(') {
        let Some(end) = name[start..].find(')') else {
            break;
        };
        without_parentheses.push_str(&name[..start]);
        without_parentheses.push(' ');
        name = name[start + end + 1..].to_owned();
    }
    without_parentheses.push_str(&name);
    name = without_parentheses
        .chars()
        .map(|c| {
            if c.is_whitespace() || c == '_' {
                '-'
            } else {
                c
            }
        })
        .collect();
    while let Some((prefix, suffix)) = name.split_once('/') {
        if prefix.is_empty()
            || !prefix
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
        {
            break;
        }
        name = suffix.to_owned();
    }
    while name.contains("--") {
        name = name.replace("--", "-");
    }
    name = name.trim_matches('-').to_owned();
    let stripped = ["xhigh", "high", "medium", "low", "fast", "thinking"]
        .iter()
        .find_map(|s| name.strip_suffix(&format!("-{s}")))
        .unwrap_or(&name);
    let mut output = Vec::new();
    for base in [&name, stripped] {
        for key in [
            base.to_string(),
            numeric_separators(base, '.', '-'),
            numeric_separators(base, '-', '.'),
        ] {
            if !key.is_empty() && !output.contains(&key) {
                output.push(key);
            }
        }
    }
    output
}

pub fn find_price(model: Option<&str>) -> Value {
    let Some(model) = model.filter(|s| !s.is_empty()) else {
        return Value::Null;
    };
    let key = model.trim().to_lowercase();
    let mut keys = vec![key.clone()];
    keys.extend(candidates(model).into_iter().filter(|c| c != &key));
    for (index, key) in keys.iter().enumerate() {
        for entry in catalog()["entries"].as_array().unwrap() {
            if entry["id"].as_str().unwrap().to_lowercase() == *key
                || entry["aliases"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|a| a.as_str().unwrap().to_lowercase() == *key)
            {
                let mut output = json!({});
                for name in [
                    "perMTok",
                    "tiers",
                    "timeOfDay",
                    "provisional",
                    "tier",
                    "billing",
                    "id",
                    "sourceUrl",
                    "verifiedAt",
                    "conditions",
                ] {
                    output[name] = entry[name].clone();
                }
                output["matchedBy"] = json!(if index == 0 { "exact" } else { "normalized" });
                return output;
            }
        }
    }
    Value::Null
}

pub(super) fn english_note(id: Option<&str>) -> Option<&'static str> {
    let id = id?;
    catalog()["entries"]
        .as_array()?
        .iter()
        .find(|entry| entry["id"].as_str() == Some(id))?["conditionsEn"]
        .as_str()
}

pub fn local_provider(provider: Option<&str>) -> Option<String> {
    let id = provider?.to_lowercase();
    catalog()["localProviders"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value.as_str() == Some(&id))
        .then_some(id)
}

pub fn classify_price(model: Option<&str>) -> Value {
    let price = find_price(model);
    if price.is_null() {
        json!({"state":"unknown","billing":"metered","id":null,"sourceUrl":null,"note":null,"provisional":false,"matchedBy":null})
    } else {
        json!({"state":price["tier"],"billing":price["billing"].as_str().filter(|s| !s.is_empty()).unwrap_or("metered"),"id":price["id"],"sourceUrl":price["sourceUrl"].as_str().filter(|s| !s.is_empty()),"note":price["conditions"].as_str().filter(|s| !s.is_empty()),"provisional":price["provisional"],"matchedBy":price["matchedBy"]})
    }
}

fn timestamp(value: &Value) -> Option<i64> {
    let text = super::jscompat::normalize_timestamp(value, &super::jscompat::LocalZone::System)?;
    DateTime::parse_from_rfc3339(&text)
        .ok()
        .map(|d| d.timestamp_millis())
}

fn overlap(tod: &Value, day: i64, from: i64, to: i64) -> i64 {
    let date = DateTime::<Utc>::from_timestamp_millis(day).unwrap();
    if tod["holidays"]
        .as_array()
        .unwrap()
        .contains(&json!(date.format("%Y-%m-%d").to_string()))
    {
        return 0;
    }
    tod["peak"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|w| {
            w["days"]
                .as_array()
                .unwrap()
                .contains(&json!(date.weekday().num_days_from_sunday()))
        })
        .map(|w| {
            (to.min(day + w["to"].as_i64().unwrap() * 60000)
                - from.max(day + w["from"].as_i64().unwrap() * 60000))
            .max(0)
        })
        .sum()
}

pub fn price_record(record: &Value) -> Value {
    price_record_with(record, || Cow::Owned(find_price(record["model"].as_str())))
}

pub(super) fn price_record_with<'a>(
    record: &Value,
    model_price: impl FnOnce() -> Cow<'a, Value>,
) -> Value {
    let provider = record["provider"].as_str().map(str::to_lowercase);
    if let Some(provider) = provider.filter(|p| {
        catalog()["localProviders"]
            .as_array()
            .unwrap()
            .contains(&json!(p))
    }) {
        return json!({"cost_micros":0,"price_version":PRICE_VERSION,"price_source":format!("local:{provider}"),"parts":{"input":0,"output":0,"cache_read":0,"cache_write":0}});
    }
    let price = model_price();
    if price.is_null() {
        return json!({"cost_micros":null,"price_version":PRICE_VERSION,"price_source":null,"parts":null});
    }
    let mut table = &price["perMTok"];
    let mut mark = String::new();
    let mut blend: Option<(i128, i128)> = None;
    let cumulative = record["kind"] == "cumulative";
    let tod = &price["timeOfDay"];
    if !tod.is_null() {
        let start = timestamp(&record["observed_at"]);
        let end = timestamp(&record["ended_at"]);
        let offset = tod["utcOffsetMinutes"].as_i64().unwrap() * 60000;
        match (start, end) {
            (Some(start), _) if !cumulative => {
                let local = start + offset;
                if overlap(tod, local - local.rem_euclid(86400000), local, local + 1) > 0 {
                    mark = ";tod:peak".into();
                } else {
                    table = &tod["offPeak"];
                    mark = ";tod:offpeak".into();
                }
            }
            (Some(start), Some(end)) if cumulative && end > start => {
                let from = start + offset;
                let to = end + offset;
                let mut peak = 0;
                let mut day = from - from.rem_euclid(86400000);
                while day < to {
                    peak += overlap(tod, day, from, to);
                    day += 86400000;
                }
                mark = ";tod:blend".into();
                blend = Some((peak as i128, (to - from - peak) as i128));
            }
            _ => {
                let peak: i64 = tod["peak"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|w| {
                        (w["to"].as_i64().unwrap() - w["from"].as_i64().unwrap())
                            * 60000
                            * w["days"].as_array().unwrap().len() as i64
                    })
                    .sum();
                mark = ";tod:weekly".into();
                blend = Some((peak as i128, (7 * 86400000 - peak) as i128));
            }
        }
    } else if let Some(tiers) = price["tiers"].as_array() {
        if cumulative {
            mark = ";tier:cumulative".into();
        } else {
            let prompt = ["input_tokens", "cache_read_tokens", "cache_write_tokens"];
            let known: i64 = prompt
                .iter()
                .map(|f| record[*f].as_i64().unwrap_or(0))
                .sum();
            if let Some(tier) = tiers
                .iter()
                .rev()
                .find(|tier| known > tier["above"].as_i64().unwrap())
            {
                table = &tier["perMTok"];
                mark = format!(";tier:{}", tier["above"]);
            } else if prompt.iter().any(|f| record[*f].is_null()) {
                mark = ";tier:unknown".into();
            }
        }
    }
    let rate = |table: &Value, key: &str| -> i128 {
        let value = if key == "cacheWrite1h" && table[key].is_null() {
            &table["cacheWrite"]
        } else {
            &table[key]
        };
        (value.as_f64().unwrap_or(0.0) * 1e6 + 0.5).floor() as i128
    };
    let part = |name: &str, key: &str| -> i64 {
        let tokens = record[name].as_i64().unwrap_or(0) as i128;
        let amount = if let Some((peak, off)) = blend {
            tokens * (rate(table, key) * peak + rate(&tod["offPeak"], key) * off)
                / ((peak + off) * 1000000)
        } else {
            tokens * rate(table, key) / 1000000
        };
        i64::try_from(amount).expect("safe log amounts fit micro-USD")
    };
    let mut parts = json!({"input":part("input_tokens","input"),"output":part("output_tokens","output"),"cache_read":part("cache_read_tokens","cacheRead"),"cache_write":0});
    parts["cache_write"] = json!(if !record["cache_write_5m_tokens"].is_null()
        || !record["cache_write_1h_tokens"].is_null()
    {
        part("cache_write_5m_tokens", "cacheWrite") + part("cache_write_1h_tokens", "cacheWrite1h")
    } else {
        part("cache_write_tokens", "cacheWrite")
    });
    let total: i64 = parts
        .as_object()
        .unwrap()
        .values()
        .map(|v| v.as_i64().unwrap())
        .sum();
    json!({"cost_micros":total,"price_version":PRICE_VERSION,"price_source":format!("{}:{}{mark}",price["tier"].as_str().unwrap(),price["id"].as_str().unwrap()),"parts":parts})
}

pub fn cost_of(record: &Value) -> Value {
    let mut output = price_record(record);
    output.as_object_mut().unwrap().remove("parts");
    output
}

pub fn format_micros(micros: Option<i64>, scale: usize) -> Option<String> {
    micros.map(|value| {
        let absolute = value.unsigned_abs();
        let fraction = format!("{:06}", absolute % 1000000);
        format!(
            "{}{}.{}",
            if value < 0 { "-" } else { "" },
            absolute / 1000000,
            &fraction[..scale.min(6)]
        )
    })
}

pub fn allocate_display(values: &[i64], total: i64, scale: usize) -> Vec<String> {
    let step = 1000000.0 / 10_f64.powi(scale as i32);
    let mut floors: Vec<i64> = values
        .iter()
        .map(|v| (*v as f64 / step).floor() as i64)
        .collect();
    let mut remainder = (total as f64 / step).floor() as i64 - floors.iter().sum::<i64>();
    let mut order: Vec<usize> = (0..values.len()).collect();
    order.sort_by(|a, b| {
        let rem = |i: usize| values[i] as f64 / step - (values[i] as f64 / step).floor();
        rem(*b).total_cmp(&rem(*a)).then(a.cmp(b))
    });
    let mut cursor = 0;
    while remainder > 0 && !order.is_empty() {
        floors[order[cursor % order.len()]] += 1;
        remainder -= 1;
        cursor += 1;
    }
    floors
        .iter()
        .map(|n| format_micros(Some((*n as f64 * step).round() as i64), scale).unwrap())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trial_catalog_estimates_new_models_and_tier_boundaries() {
        for (model, input, expected) in [
            ("gpt-6.2-sol", 271_000, 552_100),
            ("gpt-6.2-sol", 271_001, 1_099_204),
            ("gpt-6.2-astra", 271_000, 2_208_400),
            ("gpt-6.2-astra", 271_001, 4_396_816),
            ("grok-4.6", 198_999, 404_498),
            ("grok-4.6", 199_000, 809_000),
            ("gemini-4-neon", 1000, 18_150),
        ] {
            let result = price_record(&json!({"model":model,"input_tokens":input,
                "output_tokens":1000,"cache_read_tokens":1000,"cache_write_tokens":0}));
            assert_eq!(result["cost_micros"], expected, "{model} input={input}");
        }
        for model in [
            "gemini-4-hydrogen-tiered-high",
            "gemini-3.8-flash-s",
            "gemini-3.8-flash-k",
        ] {
            assert!(
                price_record(&json!({"model":model,"input_tokens":1000}))["cost_micros"].is_null()
            );
        }
    }

    #[test]
    fn trial_catalog_deepseek_peak_and_public_holidays() {
        for (date, expected) in [
            ("2027-01-04T01:00:00Z", 5324),
            ("2027-01-04T04:00:00Z", 2662),
            ("2027-01-01T01:00:00Z", 2662),
            ("2026-10-10T01:00:00Z", 2662),
        ] {
            let result = price_record(&json!({"model":"deepseek-v4-pro","kind":"delta",
                "observed_at":date,"input_tokens":1000,"output_tokens":1000,"cache_read_tokens":1000}));
            assert_eq!(result["cost_micros"], expected, "{date}");
        }
        let flash = find_price(Some("deepseek-flash"));
        let pro = find_price(Some("deepseek-v4-pro"));
        let holidays = |price: &Value| {
            price["timeOfDay"]["holidays"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|day| day.as_str().unwrap().starts_with("2027-"))
                .cloned()
                .collect::<Vec<_>>()
        };
        assert_eq!(holidays(&flash).len(), 29);
        assert_eq!(holidays(&flash), holidays(&pro));
    }

    #[test]
    fn borrowed_model_price_preserves_record_pricing() {
        for line in include_str!("../../tests/golden/pricing.jsonl").lines() {
            let mut row: Value = serde_json::from_str(line).unwrap();
            super::super::update_golden_price_version(&mut row);
            if row["type"] == "price" {
                let record = &row["record"];
                let price = find_price(record["model"].as_str());
                assert_eq!(
                    price_record_with(record, || Cow::Borrowed(&price)),
                    row["expected"],
                    "{line}"
                );
            }
        }
        let local = json!({"model":"claude-opus-5-5","provider":"OLLaMa"});
        let result = price_record_with(&local, || panic!("local pricing takes precedence"));
        assert_eq!(result["cost_micros"], 0);
        assert_eq!(result["price_source"], "local:ollama");
    }

    #[test]
    fn pricing_matches_node() {
        assert_eq!(catalog_version(), PRICE_VERSION);
        assert_eq!(catalog()["entries"].as_array().unwrap().len(), 36);
        for line in include_str!("../../tests/golden/pricing.jsonl").lines() {
            let mut row: Value = serde_json::from_str(line).unwrap();
            super::super::update_golden_price_version(&mut row);
            if row["type"] == "price" {
                assert_eq!(price_record(&row["record"]), row["expected"], "{line}");
                assert_eq!(cost_of(&row["record"]), row["cost"], "{line}");
            }
            match row["fn"].as_str() {
                Some("findPrice") => {
                    let mut actual = find_price(row["model"].as_str());
                    if actual["id"] == "deepseek-flash" {
                        actual["timeOfDay"]["holidays"]
                            .as_array_mut()
                            .unwrap()
                            .retain(|day| !day.as_str().unwrap().starts_with("2027-"));
                        actual["conditions"] = json!(actual["conditions"]
                            .as_str()
                            .unwrap()
                            .replace("登记 2026 和 2027 年", "登记 2026 年"));
                    }
                    assert_eq!(actual, row["expected"], "{line}")
                }
                Some("format") => assert_eq!(
                    json!(format_micros(
                        row["micros"].as_i64(),
                        row["scale"].as_u64().unwrap() as usize
                    )),
                    row["expected"],
                    "{line}"
                ),
                Some("allocate") => {
                    let values: Vec<i64> = row["values"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_i64().unwrap())
                        .collect();
                    assert_eq!(
                        json!(allocate_display(
                            &values,
                            row["total"].as_i64().unwrap(),
                            row["scale"].as_u64().unwrap() as usize
                        )),
                        row["expected"],
                        "{line}"
                    );
                }
                _ => {}
            }
        }
    }
}
