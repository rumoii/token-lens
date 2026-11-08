use crate::stats::{
    clock::Clock, ingest, jscompat::LocalZone, ledger::Ledger, pricing, service, timezone,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct StatsFilter {
    pub from: Option<String>,
    pub to: Option<String>,
    pub source: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTotals {
    pub gross_tokens: i64,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub cost_usd: Option<String>,
    pub cost_micros: Option<i64>,
    pub unpriced_records: i64,
    pub record_count: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsActivity {
    pub sessions: i64,
    pub turns: i64,
    pub cache_hit_ratio: Option<f64>,
    pub first_seen: Option<String>,
    pub last_seen: Option<String>,
    pub active_span_ms: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsWindow {
    pub gross_tokens: i64,
    pub cost_usd: Option<String>,
    pub cost_micros: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRolling {
    pub last_7d: StatsWindow,
    pub last_30d: StatsWindow,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSnapshot {
    pub generated_at: String,
    pub price_version: String,
    pub tz: String,
    pub filters: StatsAppliedFilter,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsAppliedFilter {
    pub from: String,
    pub to: String,
    pub source: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
    #[serde(rename = "offsetMinutes")]
    pub offset_minutes: i32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSummary {
    pub totals: StatsTotals,
    pub activity: StatsActivity,
    pub rolling: StatsRolling,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsCostParts {
    pub input: String,
    pub output: String,
    pub cache_read: String,
    pub cache_write: String,
    pub input_micros: i64,
    pub output_micros: i64,
    pub cache_read_micros: i64,
    pub cache_write_micros: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsGroup {
    pub key: Option<String>,
    pub source: Option<String>,
    pub model: Option<String>,
    pub gross_tokens: i64,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub cost_usd: Option<String>,
    pub cost_micros: Option<i64>,
    pub unpriced_records: i64,
    pub record_count: i64,
    pub price_state: Option<String>,
    pub cost_by_kind: Option<StatsCostParts>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsBreakdown {
    pub by: String,
    pub groups: Vec<StatsGroup>,
    pub totals: StatsTotals,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct StatsCounts {
    #[serde(default)]
    pub read_failed: i64,
    #[serde(default)]
    pub bad_lines: i64,
    #[serde(default)]
    pub bad_fields: i64,
    #[serde(default)]
    pub bad_times: i64,
    #[serde(default)]
    pub zero_usage: i64,
    #[serde(default)]
    pub cross_file_copies: i64,
    #[serde(default)]
    pub relabeled: i64,
    #[serde(default)]
    pub reactivated: i64,
    #[serde(default)]
    pub replaced: i64,
    #[serde(default)]
    pub deactivated: i64,
    #[serde(default)]
    pub vanished: i64,
    #[serde(default)]
    pub rev_corrections: i64,
    #[serde(default)]
    pub cumulative_decrease: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRun {
    pub id: i64,
    pub status: String,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
    pub attempted: i64,
    pub inserted: i64,
    pub updated: i64,
    pub unchanged: i64,
    pub rejected: i64,
    pub counts: Option<StatsCounts>,
    pub anomalies: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSync {
    pub attempted: i64,
    pub inserted: i64,
    pub updated: i64,
    pub unchanged: i64,
    pub rejected: i64,
    pub repriced: i64,
    pub counts: StatsCounts,
    pub anomalies: Vec<String>,
    #[serde(rename = "fileCount")]
    pub file_count: i64,
    #[serde(rename = "durationMs")]
    pub duration_ms: i64,
}

struct State {
    data: PathBuf,
    home: PathBuf,
    timezone: String,
    closed: AtomicBool,
    running: AtomicBool,
}

#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct StatsClient {
    state: Arc<State>,
}

// The core retains the exact /api/v1 shapes. Only the typed FFI adds integer money.
fn with_micros(mut value: Value) -> Value {
    fn parse(usd: &Value) -> Option<i64> {
        let text = usd.as_str()?;
        let negative = text.starts_with('-');
        let (whole, fraction) = text.trim_start_matches('-').split_once('.')?;
        let amount = whole
            .parse::<i64>()
            .ok()?
            .checked_mul(1000000)?
            .checked_add(fraction.parse::<i64>().ok()?)?;
        Some(if negative { -amount } else { amount })
    }
    fn enrich(value: &mut Value) {
        if let Some(object) = value.as_object_mut() {
            if let Some(usd) = object.get("cost_usd") {
                let micros = parse(usd);
                object.insert("cost_micros".into(), json!(micros));
            }
            if ["input", "output", "cache_read", "cache_write"]
                .iter()
                .all(|key| object.get(*key).is_some_and(Value::is_string))
            {
                for key in ["input", "output", "cache_read", "cache_write"] {
                    object.insert(format!("{key}_micros"), json!(parse(&object[key])));
                }
            }
            for child in object.values_mut() {
                enrich(child);
            }
        } else if let Some(array) = value.as_array_mut() {
            for child in array {
                enrich(child);
            }
        }
    }
    enrich(&mut value);
    value
}

impl StatsClient {
    pub fn new(data_dir: String, logs_home: Option<String>) -> Result<Self, String> {
        let data = PathBuf::from(data_dir);
        if !data.is_absolute() {
            return Err("preview directory must be absolute".into());
        }
        let home = logs_home
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .map(PathBuf::from)
            })
            .ok_or("logs home unavailable")?;
        if !home.is_absolute() {
            return Err("logs home must be absolute".into());
        }
        if pricing::catalog_version() != pricing::PRICE_VERSION {
            return Err("pricing catalog version mismatch".into());
        }
        // Construction neither discovers logs nor starts ingestion.
        drop(Ledger::open(&data.join("ledger.db"), Clock::System).map_err(|e| e.to_string())?);
        Ok(Self {
            state: Arc::new(State {
                data,
                home,
                timezone: timezone::system_timezone().map_err(|e| e.to_string())?,
                closed: AtomicBool::new(false),
                running: AtomicBool::new(false),
            }),
        })
    }
    pub fn sync(&self) -> Result<StatsSync, String> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        if self
            .state
            .running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err("SYNC_BUSY: 已有同步或采集任务在执行中".into());
        }
        struct Running<'a>(&'a AtomicBool);
        impl Drop for Running<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::Release);
            }
        }
        let _running = Running(&self.state.running);
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        let result = ingest::sync(
            &self.state.data,
            &self.state.home,
            &ingest::Environment::process(),
            Clock::System,
            &LocalZone::System,
            &self.state.closed,
        )
        .map_err(|e| e.to_string())?;
        serde_json::from_value(result).map_err(|e| e.to_string())
    }
    pub fn summary(
        &self,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsSummary, String> {
        let ledger = self.open()?;
        let value = service::summary(
            &ledger,
            &serde_json::to_value(filter).unwrap(),
            offset_minutes,
            &self.state.timezone,
        )
        .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn breakdown(
        &self,
        by: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsBreakdown, String> {
        let ledger = self.open()?;
        let mut params = serde_json::to_value(filter).unwrap();
        params["by"] = json!(by);
        let value = service::breakdown(&ledger, &params, offset_minutes, &self.state.timezone)
            .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn last_run(&self) -> Result<Option<StatsRun>, String> {
        let value = self.open()?.last_run().map_err(|e| e.to_string())?;
        serde_json::from_value(value).map_err(|e| e.to_string())
    }
    pub async fn shutdown(&self) {
        self.state.closed.store(true, Ordering::Release);
        while self.state.running.load(Ordering::Acquire) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

impl StatsClient {
    #[flutter_rust_bridge::frb(ignore)]
    fn open(&self) -> Result<Ledger, String> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        Ledger::open(&self.state.data.join("ledger.db"), Clock::System).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn typed_ffi_synthetic_home_and_repeated_shutdown() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let client = StatsClient::new(
            directory.path().join("data").to_string_lossy().into(),
            Some(home.to_string_lossy().into()),
        )
        .unwrap();
        assert_eq!(
            client
                .summary(StatsFilter::default(), 0)
                .unwrap()
                .totals
                .cost_micros,
            Some(0)
        );
        assert!(client.last_run().unwrap().is_none());
        assert_eq!(client.sync().unwrap().file_count, 0);
        assert_eq!(client.last_run().unwrap().unwrap().status, "ok");
        client.shutdown().await;
        client.shutdown().await;
        assert!(client.sync().is_err());
    }
}
