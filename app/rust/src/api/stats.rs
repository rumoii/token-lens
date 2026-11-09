use crate::stats::{
    clock::Clock, ingest, jscompat::LocalZone, ledger::Ledger, pricing, service, timezone,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
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
    pub granularity: Option<String>,
    pub by: Option<String>,
    pub known_sources: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsAppliedFilter {
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
    pub source: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
    #[serde(rename = "offsetMinutes", default)]
    pub offset_minutes: i32,
    pub session_id: Option<String>,
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsBucket {
    pub bucket: String,
    pub key: Option<String>,
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
pub struct StatsUnallocated {
    pub gross_tokens: i64,
    pub cost_usd: Option<String>,
    pub cost_micros: Option<i64>,
    pub record_count: i64,
    pub reason: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTimeseries {
    pub granularity: String,
    pub points: Vec<StatsBucket>,
    pub unallocated: Option<StatsUnallocated>,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsMatrix {
    pub granularity: String,
    pub by: String,
    pub rows: Vec<StatsBucket>,
    pub unallocated: Option<StatsUnallocated>,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionItem {
    pub source: String,
    pub session_id: String,
    pub project_key: Option<String>,
    pub started_at: String,
    pub last_seen_at: String,
    pub gross_tokens: i64,
    pub cost_usd: Option<String>,
    pub cost_micros: Option<i64>,
    pub record_count: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessions {
    pub items: Vec<StatsSessionItem>,
    pub next_cursor: Option<String>,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionSummary {
    pub source: String,
    pub session_id: String,
    pub project_key: Option<String>,
    pub started_at: String,
    pub last_seen_at: String,
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
pub struct StatsSessionModel {
    pub model: Option<String>,
    pub price_state: String,
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
pub struct StatsSessionKinds {
    pub event: i64,
    pub cumulative: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionDetail {
    pub session: StatsSessionSummary,
    pub models: Vec<StatsSessionModel>,
    pub timeline: Vec<StatsBucket>,
    pub kinds: StatsSessionKinds,
    pub granularity: String,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRetention {
    pub reviewable: i64,
    pub logs_gone: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSourceChecks {
    pub time_out_of_range: i64,
    pub huge_requests: i64,
    pub null_model: i64,
    pub mixed_kind_sessions: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSourceNote {
    pub text: String,
    pub impact: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSource {
    pub source: String,
    pub evidence: String,
    pub status: String,
    pub first_observed_at: Option<String>,
    pub last_observed_at: Option<String>,
    pub records: i64,
    pub record_mode: String,
    pub retention: StatsRetention,
    pub checks: StatsSourceChecks,
    pub limits: Vec<String>,
    pub notes: Vec<StatsSourceNote>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSourceRun {
    pub status: String,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub attempted: i64,
    pub inserted: i64,
    pub updated: i64,
    pub unchanged: i64,
    pub rejected: i64,
    pub anomaly_count: i64,
    pub counts: Option<HashMap<String, i64>>,
    pub anomalies: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSources {
    pub sources: Vec<StatsSource>,
    pub last_run: Option<StatsSourceRun>,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscoveredSource {
    pub source: String,
    pub files: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscovery {
    pub sources: Vec<StatsDiscoveredSource>,
    pub supported: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsPrices {
    pub input: Option<f64>,
    pub output: Option<f64>,
    pub cache_read: Option<f64>,
    pub cache_write_5m: Option<f64>,
    pub cache_write_1h: Option<f64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsPriceTier {
    pub above: i64,
    pub prices: StatsPrices,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsPricePeak {
    pub days: Vec<i32>,
    pub from: i32,
    pub to: i32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTimeOfDay {
    pub utc_offset_minutes: i32,
    pub peak: Vec<StatsPricePeak>,
    pub off_peak_prices: StatsPrices,
    pub holidays_count: i64,
    pub holidays_through: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsModelPrice {
    pub model: Option<String>,
    pub records: i64,
    pub state: String,
    pub billing: String,
    pub source_url: Option<String>,
    pub note: Option<String>,
    pub local_records: i64,
    pub local_providers: HashMap<String, i64>,
    pub prices: Option<StatsPrices>,
    pub tiers: Option<Vec<StatsPriceTier>>,
    pub time_of_day: Option<StatsTimeOfDay>,
    pub price_marks: HashMap<String, i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsPriceCounts {
    pub verified: i64,
    pub aggregate: i64,
    pub unknown: i64,
    pub local: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsPricing {
    pub price_version: String,
    pub verified_at: Option<String>,
    pub currency: String,
    pub provisional: bool,
    pub models: Vec<StatsModelPrice>,
    pub counts: StatsPriceCounts,
    pub snapshot: StatsSnapshot,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsHealth {
    pub ok: bool,
    pub version: String,
    pub data_dir: String,
    pub ledger_path: String,
    pub schema_version: i64,
}

struct State {
    data: PathBuf,
    home: PathBuf,
    timezone: String,
    closed: AtomicBool,
    running: AtomicBool,
    clock: Clock,
    discovery: Mutex<Option<(i64, StatsDiscovery)>>,
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
                clock: Clock::System,
                discovery: Mutex::new(None),
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
    pub fn timeseries(
        &self,
        granularity: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsTimeseries, String> {
        let ledger = self.open()?;
        let mut params = serde_json::to_value(filter).unwrap();
        params["granularity"] = json!(granularity);
        let value = service::timeseries(&ledger, &params, offset_minutes, &self.state.timezone)
            .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn matrix(
        &self,
        granularity: String,
        by: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsMatrix, String> {
        let ledger = self.open()?;
        let mut params = serde_json::to_value(filter).unwrap();
        params["granularity"] = json!(granularity);
        params["by"] = json!(by);
        let value = service::matrix(&ledger, &params, offset_minutes, &self.state.timezone)
            .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn sessions(
        &self,
        limit: Option<i64>,
        cursor: Option<String>,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsSessions, String> {
        let ledger = self.open()?;
        let mut params = serde_json::to_value(filter).unwrap();
        params["limit"] = json!(limit);
        params["cursor"] = json!(cursor);
        let value = service::sessions(&ledger, &params, offset_minutes, &self.state.timezone)
            .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn session_detail(
        &self,
        source: String,
        session_id: String,
        granularity: String,
        offset_minutes: i32,
    ) -> Result<Option<StatsSessionDetail>, String> {
        let ledger = self.open()?;
        let value = service::session_detail(
            &ledger,
            &json!({"source":source,"session_id":session_id,"granularity":granularity}),
            offset_minutes,
            &self.state.timezone,
        )
        .map_err(|e| e.to_string())?;
        value
            .map(|value| serde_json::from_value(with_micros(value)).map_err(|e| e.to_string()))
            .transpose()
    }
    pub fn sources(&self) -> Result<StatsSources, String> {
        let ledger = self.open()?;
        let value = service::sources(
            &ledger,
            &self.state.clock.iso(),
            |path| std::path::Path::new(path).exists(),
            &self.state.timezone,
        )
        .map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn discovery(&self, fresh: bool) -> Result<StatsDiscovery, String> {
        self.discovery_with_env(fresh, &ingest::Environment::process())
    }
    pub fn pricing(&self) -> Result<StatsPricing, String> {
        let ledger = self.open()?;
        let value = service::pricing(&ledger, &self.state.timezone).map_err(|e| e.to_string())?;
        serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
    }
    pub fn health(&self) -> Result<StatsHealth, String> {
        let ledger = self.open()?;
        let schema_version: i64 = ledger
            .db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|e| e.to_string())?;
        serde_json::from_value(json!({"ok":true,"version":env!("CARGO_PKG_VERSION"),"data_dir":self.state.data.to_string_lossy(),"ledger_path":self.state.data.join("ledger.db").to_string_lossy(),"schema_version":schema_version})).map_err(|e| e.to_string())
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
    fn discovery_with_env(
        &self,
        fresh: bool,
        environment: &ingest::Environment,
    ) -> Result<StatsDiscovery, String> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        let mut cache = self
            .state
            .discovery
            .lock()
            .map_err(|_| "discovery cache poisoned".to_string())?;
        let now = self.state.clock.millis();
        if !fresh {
            if let Some((at, value)) = cache.as_ref() {
                if now - at < 60000 {
                    return Ok(value.clone());
                }
            }
        }
        let value = service::discovery(&self.state.home, environment).map_err(|e| e.to_string())?;
        let value: StatsDiscovery = serde_json::from_value(value).map_err(|e| e.to_string())?;
        *cache = Some((now, value.clone()));
        Ok(value)
    }
    #[flutter_rust_bridge::frb(ignore)]
    fn open(&self) -> Result<Ledger, String> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        Ledger::open(&self.state.data.join("ledger.db"), self.state.clock.clone())
            .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn d33_health_has_preview_paths_and_no_port() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let data = temp.path().join("data");
        let client = StatsClient::new(
            data.to_string_lossy().into(),
            Some(home.to_string_lossy().into()),
        )
        .unwrap();
        let health = client.health().unwrap();
        assert!(health.ok);
        assert_eq!(health.version, env!("CARGO_PKG_VERSION"));
        assert_eq!(health.data_dir, data.to_string_lossy());
        assert_eq!(health.ledger_path, data.join("ledger.db").to_string_lossy());
        assert_eq!(health.schema_version, 5);
        assert!(serde_json::to_value(health).unwrap().get("port").is_none());
    }
    #[test]
    fn d33_typed_ffi_queries_and_discovery_cache() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let mut client = StatsClient::new(
            temp.path().join("data").to_string_lossy().into(),
            Some(home.to_string_lossy().into()),
        )
        .unwrap();
        Arc::get_mut(&mut client.state).unwrap().clock = Clock::Fixed(1768478400000);
        let ledger = client.open().unwrap();
        ledger.batch(&[
            json!({"record_key":"local","source":"claude","session_id":"s","model":"unlisted","provider":"OLLAMA","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":3}),
            json!({"record_key":"unknown","source":"claude","model":null,"observed_at":"2026-01-15T01:00:00.000Z","input_tokens":5})
        ],None,None,&[],pricing::cost_of).unwrap();
        ledger.db.execute_batch("INSERT INTO ingest_runs(started_at,finished_at,status,attempted,notes,counts) VALUES(1768478400,NULL,'running',2,'[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\"]','{\"bad_times\":2}')").unwrap();
        drop(ledger);
        let series = client
            .timeseries("hour".into(), StatsFilter::default(), 0)
            .unwrap();
        assert_eq!(series.points.len(), 2);
        assert_eq!(series.points[0].cost_micros, Some(0));
        assert_eq!(series.points[0].output_tokens, None);
        let matrix = client
            .matrix("day".into(), "model".into(), StatsFilter::default(), 0)
            .unwrap();
        assert!(matrix.rows.iter().any(|row| row.key.is_none()));
        let sessions = client
            .sessions(None, None, StatsFilter::default(), 0)
            .unwrap();
        assert_eq!(sessions.items[0].session_id, "s");
        assert_eq!(sessions.items[0].cost_micros, Some(0));
        let detail = client
            .session_detail("claude".into(), "s".into(), "hour".into(), 0)
            .unwrap()
            .unwrap();
        assert_eq!(detail.session.project_key, None);
        assert_eq!(detail.session.cost_micros, Some(0));
        assert_eq!(detail.snapshot.filters.session_id.as_deref(), Some("s"));
        let sources = client.sources().unwrap();
        assert_eq!(sources.sources[0].records, 2);
        let run = sources.last_run.unwrap();
        assert_eq!(run.anomaly_count, 6);
        assert_eq!(run.anomalies.len(), 5);
        assert_eq!(run.finished_at, None);
        assert_eq!(run.counts.unwrap().get("bad_times"), Some(&2));
        assert_eq!(client.health().unwrap().schema_version, 5);
        let prices = client.pricing().unwrap();
        assert_eq!(
            prices
                .models
                .iter()
                .find(|m| m.state == "local")
                .unwrap()
                .local_providers
                .get("ollama"),
            Some(&1)
        );
        assert!(prices.models.iter().all(|m| !m.price_marks.is_empty()));
        let env = ingest::Environment::default();
        assert!(client
            .discovery_with_env(false, &env)
            .unwrap()
            .sources
            .is_empty());
        let log = home.join(".claude/projects/a.jsonl");
        std::fs::create_dir_all(log.parent().unwrap()).unwrap();
        std::fs::write(&log, "").unwrap();
        assert!(client
            .discovery_with_env(false, &env)
            .unwrap()
            .sources
            .is_empty());
        assert_eq!(
            client.discovery_with_env(true, &env).unwrap().sources[0].files,
            1
        );
        std::fs::write(home.join(".claude/projects/b.jsonl"), "").unwrap();
        Arc::get_mut(&mut client.state).unwrap().clock = Clock::Fixed(1768478460000);
        assert_eq!(
            client.discovery_with_env(false, &env).unwrap().sources[0].files,
            2
        );
        let bad = StatsFilter {
            from: Some("z".into()),
            to: Some("a".into()),
            ..Default::default()
        };
        assert!(client
            .summary(bad, 0)
            .unwrap_err()
            .starts_with("INVALID_RANGE:"));
        assert!(client
            .session_detail(" ".into(), "s".into(), "hour".into(), 0)
            .unwrap_err()
            .starts_with("INVALID_PARAM:"));
        assert!(client
            .session_detail("s".into(), "missing".into(), "hour".into(), 0)
            .unwrap()
            .is_none());
    }
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
