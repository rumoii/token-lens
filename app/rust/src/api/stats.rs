#[cfg(test)]
use crate::stats::jscompat::LocalZone;
use crate::stats::{clock::Clock, ingest, ledger::Ledger, output, pricing, service, timezone};
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exclude_sources: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub missing: Option<String>,
}

#[derive(Clone, Debug)]
pub struct StatsUsageExport {
    pub by: String,
    pub period: String,
    pub filter: StatsFilter,
    pub format: String,
    pub project_paths: bool,
    pub directory: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRequestQuery {
    pub source: Option<String>,
    pub session_id: Option<String>,
    pub bucket: Option<String>,
    pub timed_only: bool,
    pub sort: String,
    pub descending: bool,
    pub limit: i64,
    pub offset: i64,
    pub include_summary: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRequest {
    pub id: String,
    pub observed_at: String,
    pub source: String,
    pub session_id: Option<String>,
    pub project_key: Option<String>,
    pub model: Option<String>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub cost_micros: Option<i64>,
    pub cost_usd: Option<String>,
    pub unpriced_records: i64,
    pub price_state: String,
    pub scope: Option<String>,
    pub status: Option<String>,
    pub ttft_ms: Option<i64>,
    pub speed_tps: Option<f64>,
    pub throughput_tps: Option<f64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRequestSlow {
    pub ttft_ms: Option<i64>,
    pub speed_tps: Option<f64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsRequests {
    pub items: Vec<StatsRequest>,
    pub total: Option<i64>,
    pub slow: Option<StatsRequestSlow>,
    pub snapshot: StatsSnapshot,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StatsMiniUsage {
    pub totals: StatsTotals,
    pub projects: Vec<StatsMiniProject>,
    pub minutes: Vec<i64>,
    pub active_models: Vec<StatsGroup>,
    pub requests: StatsRequests,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StatsMiniProject {
    pub key: Option<String>,
    pub gross_tokens: i64,
    pub cost_micros: Option<i64>,
    pub tools: Vec<StatsMiniTool>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StatsMiniTool {
    pub source: String,
    pub gross_tokens: i64,
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
    pub request_count: Option<i64>,
    pub event_gross_tokens: Option<i64>,
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
    pub bucket: Option<String>,
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
    pub timing: Option<StatsTiming>,
    pub model_timing: Option<StatsTiming>,
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
    pub request_count: Option<i64>,
    pub event_gross_tokens: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTtft {
    pub method: String,
    pub sample_count: i64,
    pub median_ms: i64,
    pub p90_ms: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSpeed {
    pub method: String,
    pub sample_count: i64,
    pub output_tokens: i64,
    pub generation_ms: i64,
    pub tokens_per_second: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTiming {
    pub request_count: i64,
    pub ttft: Option<Vec<StatsTtft>>,
    pub speed: Option<Vec<StatsSpeed>>,
    pub throughput: Option<Vec<StatsThroughput>>,
    pub turn: Option<StatsTurnTiming>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsThroughput {
    pub method: String,
    pub sample_count: i64,
    pub output_tokens: i64,
    pub duration_ms: i64,
    pub tokens_per_second: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsTurnTiming {
    pub turn_count: i64,
    pub ttft: Option<Vec<StatsTtft>>,
    pub speed: Option<Vec<StatsSpeed>>,
    pub throughput: Option<Vec<StatsThroughput>>,
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
#[flutter_rust_bridge::frb]
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
    #[serde(rename = "parsedFiles")]
    #[frb(default = 0)]
    pub parsed_files: i64,
    #[serde(rename = "cachedFiles")]
    #[frb(default = 0)]
    pub cached_files: i64,
    #[serde(rename = "skippedFiles")]
    #[frb(default = 0)]
    pub skipped_files: i64,
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
    pub request_count: Option<i64>,
    pub event_gross_tokens: Option<i64>,
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
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub unpriced_records: i64,
    pub request_count: Option<i64>,
    pub cumulative: StatsTotals,
    pub has_cumulative: bool,
    pub event_gross_tokens: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessions {
    pub items: Vec<StatsSessionItem>,
    pub next_cursor: Option<String>,
    pub snapshot: StatsSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionQuery {
    pub q: Option<String>,
    pub sort: Option<String>,
    pub dir: Option<String>,
    pub limit: Option<i64>,
    pub cursor: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsComparisonSide {
    pub totals: StatsTotals,
    pub groups: Vec<StatsGroup>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsComparison {
    pub by: String,
    pub current: StatsComparisonSide,
    pub previous: StatsComparisonSide,
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
    pub request_count: Option<i64>,
    pub event_gross_tokens: Option<i64>,
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
    pub event_gross_tokens: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionKinds {
    pub event: i64,
    pub cumulative: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSessionDetail {
    pub timing: Option<StatsTiming>,
    pub session: StatsSessionSummary,
    pub models: Vec<StatsSessionModel>,
    pub timeline: Vec<StatsBucket>,
    pub kinds: StatsSessionKinds,
    pub granularity: String,
    pub snapshot: StatsSnapshot,
    pub period: Option<StatsTotals>,
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
    pub text_en: Option<String>,
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
    pub limits_en: Option<Vec<String>>,
    pub notes: Vec<StatsSourceNote>,
}
#[flutter_rust_bridge::frb]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSourceRun {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub status: String,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub attempted: i64,
    pub inserted: i64,
    pub updated: i64,
    pub unchanged: i64,
    pub rejected: i64,
    #[serde(default)]
    #[frb(default = 0)]
    pub skipped_files: i64,
    pub anomaly_count: i64,
    pub counts: Option<HashMap<String, i64>>,
    pub anomalies: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsSources {
    pub has_successful_sync: Option<bool>,
    pub sources: Vec<StatsSource>,
    pub last_run: Option<StatsSourceRun>,
    pub snapshot: StatsSnapshot,
    #[serde(default)]
    pub discovery_issues: Option<Vec<StatsDiscoveryIssue>>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscoveredSource {
    pub source: String,
    pub files: i64,
}
#[flutter_rust_bridge::frb]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscovery {
    pub sources: Vec<StatsDiscoveredSource>,
    pub supported: i64,
    #[serde(default)]
    pub discovery_issues: Option<Vec<StatsDiscoveryIssue>>,
    #[serde(default)]
    #[frb(default = [])]
    pub tools: Vec<StatsDiscoveredTool>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscoveredTool {
    pub source: String,
    pub status: String,
    pub directories: Vec<StatsLogDirectory>,
    pub profile: Option<StatsSource>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsLogDirectory {
    pub path: String,
    pub status: String,
    pub files: i64,
    pub exists: bool,
}
#[derive(Clone, Debug)]
pub struct StatsSyncProgress {
    pub stage: String,
    pub source: Option<String>,
    pub index: i64,
    pub total: i64,
    pub files_read: i64,
    pub trigger: String,
    pub first_sync: Option<bool>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StatsDiscoveryIssue {
    pub source: String,
    pub permission_denied: i64,
    pub io_errors: i64,
    pub unreadable_entries: i64,
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
    pub note_en: Option<String>,
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
    preview: bool,
    timezone: String,
    closed: AtomicBool,
    running: AtomicBool,
    clock: Clock,
    discovery: Mutex<Option<(i64, StatsDiscovery)>>,
    progress: Mutex<Option<StatsSyncProgress>>,
    log: crate::diagnostics::RuntimeLog,
}

#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct StatsClient {
    state: Arc<State>,
}

// Core queries preserve existing fields; the typed FFI also adds integer money.
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
        let log = crate::diagnostics::RuntimeLog::new(
            std::path::Path::new(&data_dir),
            logs_home.as_deref().map(std::path::Path::new),
        );
        log.ffi(
            "StatsClient.new",
            Self::with_clock(data_dir, logs_home, Clock::System)
                .map_err(crate::startup_error::StartupCode::fallback),
        )
    }
    #[flutter_rust_bridge::frb(ignore)]
    pub fn new_with_fixed_clock(
        data_dir: String,
        logs_home: Option<String>,
        now_millis: i64,
    ) -> Result<Self, String> {
        chrono::DateTime::from_timestamp_millis(now_millis).ok_or("fixed clock out of range")?;
        Self::with_clock(data_dir, logs_home, Clock::Fixed(now_millis))
    }
    #[flutter_rust_bridge::frb(ignore)]
    fn with_clock(
        data_dir: String,
        logs_home: Option<String>,
        clock: Clock,
    ) -> Result<Self, String> {
        let client = Self::initialize(data_dir, logs_home, clock)?;
        // Construction neither discovers logs nor starts ingestion.
        let state = &client.state;
        drop(
            Ledger::open(&state.data.join("ledger.db"), state.clock.clone())
                .map_err(|e| e.to_string())?,
        );
        Ok(client)
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn initialize(
        data_dir: String,
        logs_home: Option<String>,
        clock: Clock,
    ) -> Result<Self, String> {
        let data = PathBuf::from(data_dir);
        if !data.is_absolute() {
            return Err("preview directory must be absolute".into());
        }
        let preview = logs_home.is_some();
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
        Ok(Self {
            state: Arc::new(State {
                log: crate::diagnostics::RuntimeLog::new(&data, Some(&home)),
                data,
                home,
                preview,
                timezone: timezone::system_timezone().map_err(|e| e.to_string())?,
                closed: AtomicBool::new(false),
                running: AtomicBool::new(false),
                clock,
                discovery: Mutex::new(None),
                progress: Mutex::new(None),
            }),
        })
    }
    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn for_cli(
        data_dir: String,
        logs_home: Option<String>,
        clock: Clock,
    ) -> Result<Self, String> {
        Self::initialize(data_dir, logs_home, clock)
    }
    pub fn sync_progress(&self) -> Option<StatsSyncProgress> {
        self.state.progress.lock().ok()?.clone()
    }
    pub fn sync(&self) -> Result<StatsSync, String> {
        self.sync_triggered("manual".into())
    }
    pub fn sync_triggered(&self, trigger: String) -> Result<StatsSync, String> {
        self.sync_with_env(trigger, &ingest::Environment::process())
    }
    #[cfg(test)]
    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn sync_isolated(&self) -> Result<StatsSync, String> {
        // Keep platform discovery, but resolve all directories under the synthetic home.
        self.sync_with_env(
            "manual".into(),
            &ingest::Environment {
                platform: ingest::Environment::process().platform,
                ..Default::default()
            },
        )
    }
    #[flutter_rust_bridge::frb(ignore)]
    fn sync_with_env(
        &self,
        trigger: String,
        environment: &ingest::Environment,
    ) -> Result<StatsSync, String> {
        let trigger = match trigger.as_str() {
            "startup" => "startup",
            "timer" => "timer",
            "reread" => "reread",
            "cli" => "cli",
            _ => "manual",
        };
        self.state
            .log
            .write("INFO", "sync", &format!("start trigger={trigger}"));
        let result = self.sync_inner(environment, trigger);
        if let Err(error) = &result {
            if error != "cancelled" {
                self.state.log.write(
                    "ERROR",
                    "sync",
                    &format!("end {}", crate::diagnostics::error_kind(error)),
                );
            }
        }
        self.state.log.ffi("sync", result)
    }
    #[flutter_rust_bridge::frb(ignore)]
    fn sync_inner(
        &self,
        environment: &ingest::Environment,
        trigger: &'static str,
    ) -> Result<StatsSync, String> {
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
        struct Running<'a>(&'a State);
        impl Drop for Running<'_> {
            fn drop(&mut self) {
                *self.0.progress.lock().unwrap_or_else(|e| e.into_inner()) = None;
                self.0.running.store(false, Ordering::Release);
            }
        }
        let _running = Running(&self.state);
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        let preview;
        let environment = if self.state.preview {
            preview = environment.preview();
            &preview
        } else {
            environment
        };
        let mut progress = StatsSyncProgress {
            stage: "discovering".into(),
            source: None,
            index: 0,
            total: crate::stats::adapters::PARSER_REV.len() as i64,
            files_read: 0,
            trigger: trigger.into(),
            first_sync: None,
        };
        let publish = |progress: &StatsSyncProgress| {
            *self
                .state
                .progress
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = Some(progress.clone());
        };
        publish(&progress);
        let result = ingest::sync_triggered(
            &self.state.data,
            &self.state.home,
            environment,
            self.state.clock.clone(),
            &self.state.closed,
            trigger,
            &mut |event| {
                match event {
                    ingest::Progress::Discovering { first_sync } => {
                        progress.first_sync = Some(first_sync);
                    }
                    ingest::Progress::Reading {
                        source,
                        index,
                        total,
                    } => {
                        progress.stage = "reading".into();
                        progress.source = Some(source.into());
                        progress.index = index as i64;
                        progress.total = total as i64;
                    }
                    ingest::Progress::FileRead => progress.files_read += 1,
                }
                publish(&progress);
            },
        )
        .map_err(|e| e.to_string())?;
        serde_json::from_value(result).map_err(|e| e.to_string())
    }
    pub fn summary(
        &self,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsSummary, String> {
        let result = (|| {
            let ledger = self.open()?;
            let value = service::summary(
                &ledger,
                &serde_json::to_value(filter).unwrap(),
                offset_minutes,
                &self.state.timezone,
            )
            .map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("summary", result)
    }
    pub fn breakdown(
        &self,
        by: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsBreakdown, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).unwrap();
            params["by"] = json!(by);
            let value = service::breakdown(&ledger, &params, offset_minutes, &self.state.timezone)
                .map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("breakdown", result)
    }
    pub fn mini_usage(
        &self,
        local_midnight_ms: i64,
        now_ms: i64,
        window_minutes: i32,
        exclude_sources: Vec<String>,
    ) -> Result<StatsMiniUsage, String> {
        let result = (|| {
            if !matches!(window_minutes, 15 | 30 | 60) {
                return Err("INVALID_RANGE: mini chart window must be 15, 30 or 60 minutes".into());
            }
            let ledger = self.open()?;
            let value = service::mini_usage(
                &ledger,
                local_midnight_ms,
                now_ms,
                window_minutes,
                &exclude_sources,
                &self.state.timezone,
            )
            .map_err(|e| e.to_string())?;
            serde_json::from_value(value).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("mini_usage", result)
    }

    pub fn requests(
        &self,
        filter: StatsFilter,
        query: StatsRequestQuery,
        offset_minutes: i32,
    ) -> Result<StatsRequests, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).unwrap();
            let mut options = serde_json::to_value(query).unwrap();
            options["session_source"] = options.as_object_mut().unwrap().remove("source").unwrap();
            params
                .as_object_mut()
                .unwrap()
                .extend(options.as_object().unwrap().clone());
            let value = service::requests(&ledger, &params, offset_minutes, &self.state.timezone)
                .map_err(|e| e.to_string())?;
            serde_json::from_value(value).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("requests", result)
    }
    pub fn last_run(&self) -> Result<Option<StatsRun>, String> {
        let result = (|| {
            let value = self.open()?.last_run().map_err(|e| e.to_string())?;
            serde_json::from_value(value).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("last_run", result)
    }
    pub fn timeseries(
        &self,
        granularity: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsTimeseries, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).unwrap();
            params["granularity"] = json!(granularity);
            let value = service::timeseries(&ledger, &params, offset_minutes, &self.state.timezone)
                .map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("timeseries", result)
    }
    pub fn matrix(
        &self,
        granularity: String,
        by: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsMatrix, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).unwrap();
            params["granularity"] = json!(granularity);
            params["by"] = json!(by);
            let value = service::matrix(&ledger, &params, offset_minutes, &self.state.timezone)
                .map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("matrix", result)
    }
    pub fn sessions(
        &self,
        limit: Option<i64>,
        cursor: Option<String>,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsSessions, String> {
        self.query_sessions(
            filter,
            StatsSessionQuery {
                q: None,
                sort: None,
                dir: None,
                limit,
                cursor,
            },
            offset_minutes,
        )
    }

    pub fn query_sessions(
        &self,
        filter: StatsFilter,
        query: StatsSessionQuery,
        offset_minutes: i32,
    ) -> Result<StatsSessions, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).unwrap();
            let options = serde_json::to_value(query).unwrap();
            params
                .as_object_mut()
                .unwrap()
                .extend(options.as_object().unwrap().clone());
            let value = service::sessions(&ledger, &params, offset_minutes, &self.state.timezone)
                .map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("sessions", result)
    }
    pub fn comparison(
        &self,
        by: String,
        current: StatsFilter,
        previous: StatsFilter,
        offset_minutes: i32,
    ) -> Result<StatsComparison, String> {
        let result = (|| {
            let ledger = self.open()?;
            let value = service::comparison(
                &ledger,
                &by,
                &serde_json::to_value(current).unwrap(),
                &serde_json::to_value(previous).unwrap(),
                offset_minutes,
            )
            .map_err(|e| e.to_string())?;
            serde_json::from_value(value).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("comparison", result)
    }
    pub fn session_detail(
        &self,
        source: String,
        session_id: String,
        granularity: String,
        offset_minutes: i32,
    ) -> Result<Option<StatsSessionDetail>, String> {
        self.session_detail_in_period(
            source,
            session_id,
            granularity,
            StatsFilter::default(),
            offset_minutes,
        )
    }
    pub fn session_detail_in_period(
        &self,
        source: String,
        session_id: String,
        granularity: String,
        filter: StatsFilter,
        offset_minutes: i32,
    ) -> Result<Option<StatsSessionDetail>, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut params = serde_json::to_value(filter).map_err(|e| e.to_string())?;
            params["source"] = json!(source);
            params["session_id"] = json!(session_id);
            params["granularity"] = json!(granularity);
            let value =
                service::session_detail(&ledger, &params, offset_minutes, &self.state.timezone)
                    .map_err(|e| e.to_string())?;
            value
                .map(|value| serde_json::from_value(with_micros(value)).map_err(|e| e.to_string()))
                .transpose()
        })();
        self.state.log.ffi("session_detail_in_period", result)
    }
    pub fn sources(&self) -> Result<StatsSources, String> {
        let result = (|| {
            let ledger = self.open()?;
            let value = service::sources_for(
                &ledger,
                &self.state.clock.iso(),
                |path| std::path::Path::new(path).exists(),
                &self.state.timezone,
                true,
            )
            .map_err(|e| e.to_string())?;
            let mut sources: StatsSources =
                serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())?;
            sources.discovery_issues.get_or_insert_with(Vec::new);
            Ok(sources)
        })();
        self.state.log.ffi("sources", result)
    }
    pub fn discovery(&self, fresh: bool) -> Result<StatsDiscovery, String> {
        let result = self.discovery_with_env(fresh, &ingest::Environment::process());
        self.state.log.ffi("discovery", result)
    }
    pub fn pricing(&self) -> Result<StatsPricing, String> {
        let result = (|| {
            let ledger = self.open()?;
            let value =
                service::pricing(&ledger, &self.state.timezone).map_err(|e| e.to_string())?;
            serde_json::from_value(with_micros(value)).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("pricing", result)
    }
    pub fn health(&self) -> Result<StatsHealth, String> {
        let result = (|| {
            let ledger = self.open()?;
            let schema_version: i64 = ledger
                .db
                .query_row("PRAGMA user_version", [], |row| row.get(0))
                .map_err(|e| e.to_string())?;
            serde_json::from_value(json!({"ok":true,"version":env!("CARGO_PKG_VERSION"),"data_dir":self.state.data.to_string_lossy(),"ledger_path":self.state.data.join("ledger.db").to_string_lossy(),"schema_version":schema_version})).map_err(|e| e.to_string())
        })();
        self.state.log.ffi("health", result)
    }
    pub fn export_usage(
        &self,
        request: StatsUsageExport,
        offset_minutes: i32,
    ) -> Result<String, String> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        if !output::GROUPS.contains(&request.by.as_str()) {
            return Err("Invalid export group.".into());
        }
        if !matches!(
            request.period.as_str(),
            "today"
                | "week"
                | "month"
                | "all"
                | "custom"
                | "yesterday"
                | "lastWeek"
                | "lastMonth"
                | "last7"
                | "last30"
        ) || !(-1440..=1440).contains(&offset_minutes)
            || [&request.filter.from, &request.filter.to]
                .into_iter()
                .flatten()
                .any(|day| crate::cli::calendar_day(day).is_none())
        {
            return Err("Invalid export period.".into());
        }
        let mut filter = json!(StatsFilter {
            exclude_sources: None,
            ..request.filter
        });
        service::validate_range(&filter).map_err(|e| e.to_string())?;
        filter["offsetMinutes"] = json!(offset_minutes);
        let scope = output::Scope {
            period: request.period,
            filter,
            timezone: self.state.timezone.clone(),
            paths: request.project_paths,
        };
        let clock = Clock::Fixed(self.state.clock.millis());
        let doc = output::read(&self.state.data, clock, |ledger| {
            output::breakdown(ledger, &scope, &request.by)
        })
        .map_err(|error| error.to_string())?;
        output::export(
            std::path::Path::new(&request.directory),
            &request.format,
            &request.by,
            &scope,
            &doc,
        )
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| error.to_string())
    }

    pub fn export_diagnostics(&self, directory: String) -> Result<String, String> {
        let result = (|| {
            let ledger = self.open()?;
            let mut environment = ingest::Environment::process();
            if self.state.preview {
                environment = environment.preview();
            }
            self.state
                .log
                .export(
                    &ledger,
                    &PathBuf::from(directory),
                    &self.state.home,
                    &environment,
                )
                .map(|p| p.to_string_lossy().into_owned())
        })();
        self.state.log.ffi("export_diagnostics", result)
    }
    pub fn log_error(&self, error_type: String, message: String, stack: String) {
        self.state.log.flutter_error(&error_type, &message, &stack);
    }
    pub async fn shutdown(&self) {
        use crate::diagnostics::{flush_runtime_log, LOG_FLUSH_TIMEOUT};
        use tokio::time::{timeout_at, Instant};

        self.state.closed.store(true, Ordering::Release);
        while self.state.running.load(Ordering::Acquire) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let deadline = Instant::now() + LOG_FLUSH_TIMEOUT;
        let mut flush = tokio::task::spawn_blocking(move || {
            flush_runtime_log(deadline.saturating_duration_since(Instant::now()))
        });
        if timeout_at(deadline, &mut flush).await.is_err() {
            flush.abort();
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
        let preview;
        let environment = if self.state.preview {
            preview = environment.preview();
            &preview
        } else {
            environment
        };
        let mut found =
            crate::stats::discovery::discover_profiled(&self.state.home, environment, None, true);
        let mut profiles = service::unrecorded_source_profiles().map_err(|e| e.to_string())?;
        for tool in &mut found.tools {
            tool.profile = profiles
                .remove(&tool.source)
                .map(serde_json::from_value)
                .transpose()
                .map_err(|e| e.to_string())?;
        }
        let value: StatsDiscovery = serde_json::from_value(service::discovery_summary(&found))
            .map_err(|e| e.to_string())?;
        let value = StatsDiscovery {
            discovery_issues: Some(value.discovery_issues.unwrap_or_default()),
            tools: found.tools,
            ..value
        };
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
#[path = "stats_discovery_tests.rs"]
mod discovery_tests;

#[cfg(test)]
#[path = "stats_mini_tests.rs"]
mod mini_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requests_ffi_preserves_nulls_and_session_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        let client = StatsClient::new_with_fixed_clock(
            temp.path().join("data").to_string_lossy().into(),
            Some(temp.path().join("home").to_string_lossy().into()),
            1768478400000,
        )
        .unwrap();
        client.open().unwrap().batch(&[json!({"record_key":"r","source":"codex","session_id":"s","model":"unknown","observed_at":"2026-01-15T00:00:00.000Z","input_tokens":10})],None,None,&[],pricing::cost_of).unwrap();
        let result = client
            .requests(
                StatsFilter {
                    from: Some("2025-01-01".into()),
                    ..Default::default()
                },
                StatsRequestQuery {
                    source: Some("codex".into()),
                    session_id: Some("s".into()),
                    bucket: None,
                    timed_only: false,
                    sort: "time".into(),
                    descending: true,
                    limit: 30,
                    offset: 0,
                    include_summary: true,
                },
                480,
            )
            .unwrap();
        assert_eq!(result.total, Some(1));
        assert_eq!(result.items[0].output_tokens, None);
        assert_eq!(result.items[0].cost_micros, None);
        assert_eq!(result.items[0].unpriced_records, 1);
        assert_eq!(result.snapshot.filters.session_id.as_deref(), Some("s"));
        assert_eq!(result.snapshot.filters.offset_minutes, 480);
        assert_eq!(result.snapshot.generated_at, "2026-01-15T12:00:00.000Z");
    }
    #[test]
    fn d35_fixed_clock_covers_collection_and_queries() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        std::fs::create_dir_all(home.join(".claude/projects")).unwrap();
        std::fs::copy(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/parity/ingest-a.jsonl"),
            home.join(".claude/projects/a.jsonl"),
        )
        .unwrap();
        let now = 1768478400000;
        let client = StatsClient::new_with_fixed_clock(
            temp.path().join("data").to_string_lossy().into(),
            Some(home.to_string_lossy().into()),
            now,
        )
        .unwrap();
        let seed = client.open().unwrap();
        for (key, observed, tokens) in [
            ("recent", "2026-01-14T00:00:00.000Z", 13),
            ("month", "2025-12-30T00:00:00.000Z", 17),
            ("older", "2025-11-01T00:00:00.000Z", 19),
        ] {
            seed.batch(
                &[json!({"record_key":key,"source":"claude","model":"unknown",
                "observed_at":observed,"input_tokens":tokens})],
                None,
                None,
                &[],
                pricing::cost_of,
            )
            .unwrap();
        }
        seed.db
            .execute("UPDATE usage_records SET price_version='old'", [])
            .unwrap();
        drop(seed);
        let first = client.sync_isolated().unwrap();
        assert!(first.inserted > 0);
        let second = client.sync_isolated().unwrap();
        assert_eq!((second.inserted, second.updated), (0, 0));
        let ledger = client.open().unwrap();
        let runs: Vec<(i64, i64)> = ledger
            .db
            .prepare("SELECT started_at,finished_at FROM ingest_runs ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(runs, vec![(now / 1000, now / 1000); 2]);
        let verified: String = ledger
            .db
            .query_row("SELECT verified_at FROM pricing_snapshot", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(verified, "2026-01-15");
        let summary = client.summary(StatsFilter::default(), 480).unwrap();
        assert_eq!(summary.snapshot.generated_at, "2026-01-15T12:00:00.000Z");
        assert_eq!(summary.rolling.last_7d.gross_tokens, 182);
        assert_eq!(summary.rolling.last_30d.gross_tokens, 199);
        for (days, window) in [(6, summary.rolling.last_7d), (29, summary.rolling.last_30d)] {
            let from = (chrono::DateTime::from_timestamp_millis(now).unwrap()
                + chrono::Duration::minutes(480)
                - chrono::Duration::days(days))
            .format("%Y-%m-%d")
            .to_string();
            let totals = ledger
                .totals(&json!({"from":from,"offsetMinutes":480}))
                .unwrap();
            assert_eq!(
                window.gross_tokens,
                totals["gross_tokens"].as_i64().unwrap()
            );
            assert_eq!(window.cost_micros, totals["cost_micros"].as_i64());
        }
        let system = StatsClient::new(
            temp.path().join("system-data").to_string_lossy().into(),
            Some(home.to_string_lossy().into()),
        )
        .unwrap();
        let before = chrono::Utc::now().timestamp_millis();
        let generated = system
            .summary(StatsFilter::default(), 0)
            .unwrap()
            .snapshot
            .generated_at;
        let actual = chrono::DateTime::parse_from_rfc3339(&generated)
            .unwrap()
            .timestamp_millis();
        assert!((before..=chrono::Utc::now().timestamp_millis()).contains(&actual));
        assert_ne!(actual, now);
    }
    #[test]
    fn d35_invalid_fixed_clock_does_not_initialize_a_ledger() {
        let temp = tempfile::tempdir().unwrap();
        let data = temp.path().join("data");
        assert!(StatsClient::new_with_fixed_clock(
            data.to_string_lossy().into(),
            Some(temp.path().to_string_lossy().into()),
            i64::MAX,
        )
        .is_err());
        assert!(!data.exists());
    }
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
        assert_eq!(health.schema_version, 7);
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
        assert_eq!(client.health().unwrap().schema_version, 7);
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
        assert_eq!(client.sync_isolated().unwrap().file_count, 0);
        assert_eq!(client.last_run().unwrap().unwrap().status, "ok");
        client.shutdown().await;
        client.shutdown().await;
        assert!(client.sync().is_err());
    }
}
