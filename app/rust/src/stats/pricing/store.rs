use super::{
    super::{ledger::Ledger, Error, Result},
    newer_than_builtin, parse_catalog, published_at, valid_rates, EffectivePrices, DOWNLOAD_FILE,
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::Path;

pub(super) const MANUAL_FILE: &str = "manual-prices.json";
const MAX_DOWNLOAD_BYTES: usize = 1 << 20;
const MANUAL_FIELDS: [&str; 4] = ["input", "output", "cacheRead", "cacheWrite"];

pub(crate) fn install(data: &Path, ledger: &Ledger, text: &str) -> Result<Value> {
    let Some(table) = (text.len() <= MAX_DOWNLOAD_BYTES)
        .then(|| parse_catalog(text))
        .flatten()
    else {
        return Ok(json!({"kind":"invalid"}));
    };
    if !newer_than_builtin(&table) {
        return Ok(json!({"kind":"older"}));
    }
    if ledger.prices.downloaded.as_ref() == Some(&table) {
        return Ok(json!({"kind":"unchanged"}));
    }
    let published = published_at(&table).to_owned();
    let next = EffectivePrices::from_parts(Some(table), ledger.prices.manual.clone());
    let mut newly_priced = HashSet::new();
    for row in ledger.model_price_marks()? {
        let Some(model) = row["model"].as_str() else {
            continue;
        };
        let provider = row["provider"].as_str();
        if ledger.prices.local_provider(provider).is_none()
            && ledger.prices.find_price(Some(model)).is_null()
            && (next.local_provider(provider).is_some() || !next.find_price(Some(model)).is_null())
        {
            newly_priced.insert(model.to_owned());
        }
    }
    write(data, DOWNLOAD_FILE, next.downloaded.as_ref().unwrap())?;
    Ok(json!({"kind":"installed","published_at":published,"newly_priced":newly_priced.len()}))
}

pub(crate) fn remove_download(data: &Path) -> Result<()> {
    remove(data, DOWNLOAD_FILE)
}

pub(super) fn read_manual(data: &Path) -> BTreeMap<String, Value> {
    let invalid = |reason| {
        crate::diagnostics::RuntimeLog::new(data, None).write("WARN", "pricing", reason);
        BTreeMap::new()
    };
    let text = match std::fs::read_to_string(data.join(MANUAL_FILE)) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return BTreeMap::new(),
        Err(_) => return invalid("ignoring manual prices: read failed"),
    };
    let Ok(entries) = serde_json::from_str::<BTreeMap<String, Value>>(&text) else {
        return invalid("ignoring manual prices: invalid");
    };
    if entries.iter().any(|(id, entry)| {
        id.trim().is_empty()
            || entry["model"].as_str() != Some(id)
            || manual_values(entry).is_err()
            || !valid_rates(&entry["usd"])
            || entry["createdAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .is_none()
            || entry["updatedAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .is_none()
    }) {
        return invalid("ignoring manual prices: invalid");
    }
    entries
}

fn manual_values(input: &Value) -> Result<Value> {
    let rate = match input["currency"].as_str() {
        Some("USD") => 1.0,
        Some("CNY") => input["rate"]
            .as_f64()
            .filter(|x| x.is_finite() && *x > 0.0)
            .ok_or_else(|| Error("CNY_RATE_INVALID".into()))?,
        _ => return Err(Error("CURRENCY_INVALID".into())),
    };
    if !input["note"].is_null()
        && !input["note"]
            .as_str()
            .is_some_and(|s| s.chars().count() <= 500)
    {
        return Err(Error("NOTE_TOO_LONG".into()));
    }
    let mut usd = json!({});
    for (i, k) in MANUAL_FIELDS.into_iter().enumerate() {
        let raw = &input[k];
        if i >= 2 && raw.is_null() {
            usd[k] = Value::Null;
            continue;
        }
        usd[k] = json!(raw
            .as_f64()
            .map(|x| x / rate)
            .filter(|x| x.is_finite() && (0.0..=10_000.0).contains(x))
            .ok_or_else(|| Error(format!("PRICE_OUT_OF_RANGE:{k}:0–10000 USD")))?);
    }
    usd["cacheWrite1h"] = usd["cacheWrite"].clone();
    Ok(usd)
}

pub(crate) fn save_manual(data: &Path, ledger: &Ledger, text: &str) -> Result<()> {
    let input: Value = serde_json::from_str(text)?;
    let model = input["model"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| Error("MODEL_ID_REQUIRED".into()))?;
    let existing = ledger.prices.manual.get(model);
    if existing.is_none() {
        if !ledger.prices.list_price(Some(model)).is_null() {
            return Err(Error("MODEL_ALREADY_PRICED".into()));
        }
        if !ledger.model_price_marks()?.iter().any(|row| {
            row["model"].as_str() == Some(model)
                && ledger
                    .prices
                    .local_provider(row["provider"].as_str())
                    .is_none()
        }) {
            return Err(Error("MODEL_NOT_UNPRICED".into()));
        }
    }
    let usd = manual_values(&input)?;
    let now = ledger.clock.iso();
    let mut entry = json!({
        "model":model,"currency":input["currency"],"note":input["note"],
        "createdAt":existing.map_or_else(|| json!(now), |value| value["createdAt"].clone()),
        "updatedAt":now,"usd":usd,
    });
    for key in MANUAL_FIELDS {
        entry[key] = input[key].clone();
    }
    if input["currency"] == "CNY" {
        entry["rate"] = input["rate"].clone();
    }
    let mut entries = ledger.prices.manual.clone();
    entries.insert(model.to_owned(), entry);
    write(data, MANUAL_FILE, &entries)
}

pub(crate) fn remove_manual(data: &Path, ledger: &Ledger, model: &str) -> Result<()> {
    let mut entries = ledger.prices.manual.clone();
    if entries.remove(model).is_some() {
        write(data, MANUAL_FILE, &entries)?;
    }
    Ok(())
}

fn write(data: &Path, name: &str, value: &impl serde::Serialize) -> Result<()> {
    let mut temp = tempfile::NamedTempFile::new_in(data)?;
    serde_json::to_writer(temp.as_file_mut(), value)?;
    temp.flush()?;
    temp.as_file().sync_all()?;
    temp.persist(data.join(name)).map_err(|error| error.error)?;
    Ok(())
}

fn remove(data: &Path, name: &str) -> Result<()> {
    match std::fs::remove_file(data.join(name)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::{clock::Clock, pricing, service};

    fn open(dir: &Path) -> Ledger {
        Ledger::open(&dir.join("ledger.db"), Clock::Fixed(1795305600000)).unwrap()
    }

    fn entry(id: &str) -> Value {
        let mut value = pricing::catalog()["entries"][0].clone();
        value["id"] = json!(id);
        value["aliases"] = json!([]);
        value
    }

    fn download() -> Value {
        json!({"formatVersion":1,"publishedAt":"2026-11-23","localProviders":["ollama"],"entries":[entry("new-model"),entry("another-model")]})
    }

    fn seed(ledger: &Ledger, model: &str) {
        ledger.batch(&[json!({"record_key":model,"source":"codex","session_id":"test","model":model,"observed_at":"2026-11-22T12:00:00Z","input_tokens":101,"output_tokens":30,"cache_read_tokens":12,"cache_write_tokens":21,"cache_write_5m_tokens":11,"cache_write_1h_tokens":10})],None,None,&[],pricing::cost_of).unwrap();
    }

    #[test]
    fn validates_the_download_before_touching_the_installed_file() {
        let temp = tempfile::tempdir().unwrap();
        let data = temp.path();
        let ledger = open(data);
        let valid = download();
        let mut invalid = vec!["invalid json".into(), "[]".into()];
        for (path, bad) in [
            ("/formatVersion", json!(2)),
            ("/publishedAt", Value::Null),
            ("/publishedAt", json!("2026-02-30")),
            ("/entries/0/perMTok/input", json!(-1)),
            ("/entries/1/id", json!("new-model")),
            ("/entries/1/aliases", json!(["new-model"])),
        ] {
            let mut candidate = valid.clone();
            *candidate.pointer_mut(path).unwrap() = bad;
            invalid.push(candidate.to_string());
        }
        let mut bad_tiers = valid.clone();
        bad_tiers["entries"][1]["tiers"] = json!([{"above":-1,"perMTok":{}}]);
        invalid.push(bad_tiers.to_string());
        for text in &invalid {
            assert_eq!(
                install(data, &ledger, text).unwrap()["kind"],
                "invalid",
                "{text}"
            );
            assert!(!data.join(pricing::DOWNLOAD_FILE).exists());
        }
        let mut older = valid.clone();
        older["publishedAt"] = json!("2026-11-22");
        assert_eq!(
            install(data, &ledger, &older.to_string()).unwrap()["kind"],
            "older"
        );
        assert!(!data.join(pricing::DOWNLOAD_FILE).exists());
        seed(&ledger, "new-model");
        seed(&ledger, "gpt-6.2-sol");
        let result = install(data, &ledger, &valid.to_string()).unwrap();
        assert_eq!(
            result,
            json!({"kind":"installed","published_at":"2026-11-23","newly_priced":1})
        );
        let original = std::fs::read(data.join(pricing::DOWNLOAD_FILE)).unwrap();
        let ledger = open(data);
        assert_eq!(
            install(
                data,
                &ledger,
                &serde_json::to_string_pretty(&valid).unwrap()
            )
            .unwrap()["kind"],
            "unchanged"
        );
        for text in &invalid {
            assert_eq!(install(data, &ledger, text).unwrap()["kind"], "invalid");
        }
        assert_eq!(
            std::fs::read(data.join(pricing::DOWNLOAD_FILE)).unwrap(),
            original
        );
    }

    #[test]
    fn cny_manual_price_survives_reopen_and_takes_precedence() {
        let temp = tempfile::tempdir().unwrap();
        let data = temp.path();
        let ledger = open(data);
        seed(&ledger, "new-model");
        seed(&ledger, "gpt-6.2-sol");
        let mut manual = json!({"model":"gpt-6.2-sol","currency":"CNY","rate":7,"input":7,"output":14,"cacheRead":null,"cacheWrite":3.5,"note":"example"});
        assert!(save_manual(data, &ledger, &manual.to_string()).is_err());
        manual["model"] = json!("new-model");
        save_manual(data, &ledger, &manual.to_string()).unwrap();
        let ledger = open(data);
        assert_ne!(ledger.prices.version(), pricing::PRICE_VERSION);
        assert_eq!(ledger.prices.version(), open(data).prices.version());
        let record = json!({"model":"new-model","input_tokens":101,"output_tokens":30,"cache_read_tokens":12,"cache_write_tokens":21,"cache_write_5m_tokens":11,"cache_write_1h_tokens":10});
        let value = ledger.prices.cost_of(&record);
        assert_eq!(value["price_source"], "manual:new-model");
        assert_eq!(value["cost_micros"], 171);
        assert!(ledger
            .prices
            .cost_of(&json!({"model":"NEW-MODEL","input_tokens":101}))["cost_micros"]
            .is_null());
        assert_eq!(
            install(data, &ledger, &download().to_string()).unwrap()["newly_priced"],
            0
        );
        let ledger = open(data);
        assert_eq!(ledger.prices.cost_of(&record)["cost_micros"], 171);
        let price = service::pricing(&ledger, "UTC").unwrap();
        let model = price["models"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["model"] == "new-model")
            .unwrap();
        assert_eq!(model["state"], "manual");
        assert_eq!(model["manual"]["rate"], 7.0);
        assert_eq!(model["manual"]["original"]["output"], 14.0);
        assert_eq!(model["prices"]["output"], 2.0);
        assert!(model["list_prices"]["output"].is_number());
        assert_eq!(price["counts"]["manual"], 1);
    }
}
