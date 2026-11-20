use crate::stats::{
    discovery,
    ingest::Environment,
    ledger::{self, Ledger},
};
use chrono::{DateTime, Duration, Local, NaiveDate};
use serde_json::Value;
use std::{
    fs::{self, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::Duration as StdDuration,
};

const LOG_LIMIT: u64 = 5 * 1024 * 1024;
const EXPORT_LIMIT: usize = 8 * 1024 * 1024;
const LIMIT_MARK: &str = "已达上限";
pub(crate) const LOG_FLUSH_TIMEOUT: StdDuration = StdDuration::from_millis(200);

mod writer;

pub(crate) fn flush_runtime_log(timeout: StdDuration) -> bool {
    writer::flush(timeout)
}

fn short_message(text: &str, limit: usize) -> String {
    text.split(['\r', '\n'])
        .next()
        .unwrap_or("")
        .chars()
        .take(limit)
        .collect()
}
fn stack_frames(stack: &str) -> String {
    stack.lines().map(str::trim).filter(|line| {
        let Some((number, rest)) = line.strip_prefix('#').and_then(|s| s.split_once(char::is_whitespace)) else { return false; };
        if number.is_empty() || !number.bytes().all(|c| c.is_ascii_digit()) { return false; }
        let Some((_, location)) = rest.rsplit_once(" (") else { return false; };
        let Some(location) = location.strip_suffix(')') else { return false; };
        let mut parts = location.rsplitn(3, ':');
        matches!((parts.next(), parts.next(), parts.next()), (Some(column), Some(row), Some(file)) if column.parse::<u32>().is_ok_and(|n| n > 0) && row.parse::<u32>().is_ok_and(|n| n > 0) && !file.is_empty())
    }).take(20).collect::<Vec<_>>().join("\n")
}

// Decode one path character without allocating a normalized copy of the whole export.
fn path_character(text: &str, at: usize) -> Option<(char, usize)> {
    fn byte(bytes: &[u8], at: usize) -> Option<(u8, usize)> {
        let value = *bytes.get(at)?;
        if value == b'%' {
            if let Some(hex) = bytes.get(at + 1..at + 3) {
                if let (Some(a), Some(b)) =
                    ((hex[0] as char).to_digit(16), (hex[1] as char).to_digit(16))
                {
                    return Some(((a * 16 + b) as u8, at + 3));
                }
            }
        }
        Some((value, at + 1))
    }
    fn character(text: &str, at: usize) -> Option<(char, usize)> {
        let (first, mut end) = byte(text.as_bytes(), at)?;
        if first.is_ascii() {
            return Some((first as char, end));
        }
        let count = match first {
            0xc2..=0xdf => 2,
            0xe0..=0xef => 3,
            0xf0..=0xf4 => 4,
            _ => return None,
        };
        let mut encoded = [0; 4];
        encoded[0] = first;
        for slot in &mut encoded[1..count] {
            let (value, next) = byte(text.as_bytes(), end)?;
            *slot = value;
            end = next;
        }
        Some((
            std::str::from_utf8(&encoded[..count])
                .ok()?
                .chars()
                .next()?,
            end,
        ))
    }
    let (value, mut end) = character(text, at)?;
    if matches!(value, '/' | '\\') {
        // Repeated separators also cover JSON-escaped backslashes and file URI slashes.
        while let Some((next, after)) = character(text, end) {
            if !matches!(next, '/' | '\\') {
                break;
            }
            end = after;
        }
        Some(('/', end))
    } else {
        Some((value, end))
    }
}

fn normalized_path(text: &str) -> Vec<char> {
    let mut result = Vec::new();
    let mut at = 0;
    while at < text.len() {
        if let Some((value, next)) = path_character(text, at) {
            result.push(value);
            at = next;
        } else {
            let value = text[at..].chars().next().unwrap();
            result.push(value);
            at += value.len_utf8();
        }
    }
    result
}
fn path_char_eq(a: char, b: char) -> bool {
    if cfg!(windows) {
        a.to_lowercase().eq(b.to_lowercase())
    } else {
        a == b
    }
}
fn prefix_end(text: &str, at: usize, prefix: &[char]) -> Option<usize> {
    let mut end = at;
    for expected in prefix {
        let (actual, next) = path_character(text, end)?;
        if !path_char_eq(actual, *expected) {
            return None;
        }
        end = next;
    }
    let boundary = path_character(text, end).map(|(c, _)| c);
    boundary
        .is_none_or(|c| !c.is_alphanumeric() && !matches!(c, '_' | '-'))
        .then_some(end)
}

/// Shared by runtime writes and exports: compare decoded path characters, retaining
/// original byte offsets so mixed separators, URI escapes and JSON escapes are all hidden.
pub(crate) fn redact_home(text: &str, home: Option<&Path>) -> String {
    let system =
        std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from);
    let mut prefixes = Vec::new();
    for home in home.into_iter().chain(system.as_deref()) {
        let home = home.to_string_lossy();
        let home = home.trim_end_matches(['/', '\\']);
        if home.is_empty() {
            continue;
        }
        prefixes.push(normalized_path(home));
        prefixes.push(normalized_path(&format!(
            "file:///{}",
            home.trim_start_matches(['/', '\\'])
        )));
    }
    prefixes.sort_by_key(|p| std::cmp::Reverse(p.len()));
    prefixes.dedup();
    let mut result = String::with_capacity(text.len());
    let (mut at, mut copied) = (0, 0);
    while at < text.len() {
        if let Some(end) = prefixes
            .iter()
            .find_map(|prefix| prefix_end(text, at, prefix))
        {
            result.push_str(&text[copied..at]);
            result.push('~');
            at = end;
            copied = end;
        } else {
            at += text[at..].chars().next().unwrap().len_utf8();
        }
    }
    result.push_str(&text[copied..]);
    result
}

fn redact_sensitive(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let lower = line.to_ascii_lowercase();
            let mut cut = None;
            for field in [
                "authorization",
                "proxy-authorization",
                "x-api-key",
                "api-key",
                "api_key",
                "apikey",
                "access_token",
                "cookie",
                "set-cookie",
                "headers",
                "prompt",
                "content",
                "messages",
                "arguments",
                "tool_params",
                "request_body",
            ] {
                for (index, _) in lower.match_indices(field) {
                    let before = &lower[..index];
                    let after =
                        lower[index + field.len()..].trim_start_matches(['\"', '\'', ' ', '\t']);
                    if before
                        .chars()
                        .next_back()
                        .is_none_or(|c| !c.is_alphanumeric() && c != '_')
                        && after.starts_with([':', '='])
                    {
                        cut = Some(cut.unwrap_or(index).min(index));
                    }
                }
            }
            for prefix in ["bearer ", "sk-", "ghp_", "github_pat_"] {
                if let Some(index) = lower.find(prefix) {
                    cut = Some(cut.unwrap_or(index).min(index));
                }
            }
            cut.map(|index| format!("{}[敏感内容已隐去]", &line[..index]))
                .unwrap_or_else(|| line.to_owned())
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Parser errors and record identifiers can contain arbitrary input. Preserve typed
/// diagnostic facts and hash the original note for correlation, without its payload.
pub(crate) fn safe_anomaly(note: &str, discovered_files: &[PathBuf]) -> String {
    use sha2::{Digest, Sha256};
    let kind = note.split_once(':').map(|v| v.0).unwrap_or("");
    let kind = match kind {
        "read_failed"
        | "rejected"
        | "vanished"
        | "cumulative_decrease"
        | "cross_file_conflict"
        | "superseded_reproduced"
        | "rev_correction"
        | "run_failed" => kind,
        _ => "other",
    };
    let body = note.split_once(": ").map(|v| v.1).unwrap_or("");
    let detail = match kind {
        "rejected" => {
            let reason = body.rsplit_once(" — ").map(|v| v.1).unwrap_or("");
            let safe = [
                "record_key",
                "source",
                "observed_at",
                "ended_at",
                "kind",
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cache_write_5m_tokens",
                "cache_write_1h_tokens",
            ]
            .iter()
            .find(|field| reason.starts_with(**field));
            safe.map(|field| format!("invalid-field={field}"))
                .unwrap_or_else(|| "invalid-record".into())
        }
        "read_failed" => body
            .split_once(" — ")
            .and_then(|(left, _)| left.split_once(' '))
            .filter(|(source, path)| {
                crate::stats::adapters::PARSER_REV
                    .iter()
                    .any(|s| s.0 == *source)
                    && Path::new(path).is_absolute()
            })
            .map(|(source, path)| format!("source={source} path={path} read-error"))
            .unwrap_or_else(|| "read-error".into()),
        "cross_file_conflict" => body
            .rsplit_once(" — ")
            .and_then(|(_, tail)| tail.split_once(" 的用量与 "))
            .and_then(|(left, tail)| {
                tail.strip_suffix(" 不同，按后者计")
                    .map(|right| (left, right))
            })
            .filter(|(a, b)| {
                [a, b].iter().all(|candidate| {
                    Path::new(candidate).is_absolute()
                        && discovered_files.iter().any(|file| {
                            let left = normalized_path(candidate);
                            let right = normalized_path(&file.to_string_lossy());
                            left.len() == right.len()
                                && left.iter().zip(right).all(|(a, b)| path_char_eq(*a, b))
                        })
                })
            })
            .map(|(a, b)| format!("conflicting-file={a} owner-file={b}"))
            .unwrap_or_else(|| "usage-conflict".into()),
        "cumulative_decrease" => body
            .rsplit_once(" — ")
            .and_then(|(_, tail)| tail.split_once(" → "))
            .and_then(|(a, b)| a.parse::<i64>().ok().zip(b.parse::<i64>().ok()))
            .map(|(a, b)| format!("tokens={a}->{b}"))
            .unwrap_or_else(|| "usage-decreased".into()),
        "vanished" => body
            .rsplit_once(" — ")
            .and_then(|(path, tail)| tail.split_once(' ').map(|(count, _)| (path, count)))
            .filter(|(path, _)| Path::new(path).is_absolute())
            .and_then(|(path, count)| {
                count
                    .parse::<u64>()
                    .ok()
                    .map(|n| format!("path={path} records={n} kept-previous"))
            })
            .unwrap_or_else(|| "kept-previous".into()),
        "run_failed" => error_kind(body).into(),
        _ => "dynamic-detail-omitted".into(),
    };
    format!(
        "{kind}: {detail} detail-sha256={:x} (动态内容已隐去)",
        Sha256::digest(note.as_bytes())
    )
}

pub(crate) fn error_kind(error: &str) -> &'static str {
    if let Some(code) = crate::startup_error::StartupCode::from_message(error) {
        code.as_str()
    } else if error == "cancelled" {
        "cancelled"
    } else if error == "closed" {
        "closed"
    } else if error.starts_with("SYNC_BUSY") {
        "SYNC_BUSY"
    } else if error.starts_with("LEGACY_SYNC_LOCK") {
        "LEGACY_SYNC_LOCK"
    } else if error.starts_with("INVALID_RANGE") {
        "INVALID_RANGE"
    } else if error.starts_with("INVALID_PARAM") {
        "INVALID_PARAM"
    } else {
        "operation_failed"
    }
}

fn log_date(path: &Path) -> Option<NaiveDate> {
    let name = path.file_name()?.to_str()?;
    NaiveDate::parse_from_str(
        name.strip_prefix("token-lens-")?.strip_suffix(".log")?,
        "%Y-%m-%d",
    )
    .ok()
}

fn ordinary(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !linked(&m))
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
// Retention never traverses a symlink/junction in the data path or logs directory.
fn checked_directory(path: &Path) -> std::io::Result<()> {
    for ancestor in path.ancestors() {
        if fs::symlink_metadata(ancestor).is_ok_and(|m| linked(&m)) {
            return Err(std::io::Error::other("linked log directory"));
        }
    }
    fs::create_dir_all(path)
}

pub(crate) fn os_version() -> String {
    let mut command = if cfg!(windows) {
        let mut c = std::process::Command::new("cmd");
        c.args(["/u", "/d", "/c", "ver"]);
        c
    } else if cfg!(target_os = "macos") {
        let mut c = std::process::Command::new("sw_vers");
        c.arg("-productVersion");
        c
    } else {
        let mut c = std::process::Command::new("uname");
        c.args(["-sr"]);
        c
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let version = command
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            #[cfg(windows)]
            let text = String::from_utf16_lossy(
                &o.stdout
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|pair| u16::from_le_bytes(*pair))
                    .collect::<Vec<_>>(),
            );
            #[cfg(not(windows))]
            let text = String::from_utf8_lossy(&o.stdout).into_owned();
            text.trim().to_owned()
        })
        .unwrap_or_else(|| "unknown".into());
    format!(
        "{} {} {version}",
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

#[derive(Clone)]
pub(crate) struct RuntimeLog {
    pub(crate) data: PathBuf,
    pub(crate) home: Option<PathBuf>,
}

impl RuntimeLog {
    pub(crate) fn new(data: &Path, home: Option<&Path>) -> Self {
        Self {
            data: data.into(),
            home: home.map(Path::to_path_buf),
        }
    }
    pub(crate) fn write(&self, level: &str, module: &str, message: &str) {
        self.write_at(Local::now(), level, module, message);
    }
    fn write_at(&self, date: DateTime<Local>, level: &str, module: &str, message: &str) {
        let _ = self.try_write(date, level, module, message);
    }
    fn try_write(
        &self,
        date: DateTime<Local>,
        level: &str,
        module: &str,
        message: &str,
    ) -> std::io::Result<()> {
        if !self.data.is_absolute() {
            return Ok(());
        }
        let level = match level {
            "WARN" => "WARN",
            "ERROR" => "ERROR",
            _ => "INFO",
        };
        let clean = |text: &str| {
            self.sanitize(text)
                .replace('\r', "\\r")
                .replace('\n', "\\n")
        };
        let line = format!(
            "{} {level} {} {}\n",
            date.format("%Y-%m-%d %H:%M:%S%.3f %:z"),
            clean(module),
            clean(message)
        );
        writer::submit(writer::LogLine {
            directory: self.data.join("logs"),
            date,
            text: (line.len() as u64 <= LOG_LIMIT).then(|| line.into_boxed_str()),
        })
    }
    fn sanitize(&self, text: &str) -> String {
        // Preserve the complete home until it is replaced; secret filtering can cut paths.
        redact_sensitive(&redact_home(text, self.home.as_deref()))
    }
    pub(crate) fn flutter_error(&self, error_type: &str, message: &str, stack: &str) {
        let clean_short = |text: &str, limit| short_message(&self.sanitize(text), limit);
        self.write(
            "ERROR",
            "flutter",
            &format!(
                "type={} message={} stack={}",
                clean_short(error_type, 80),
                clean_short(message, 200),
                stack_frames(&self.sanitize(stack))
            ),
        );
    }
    pub(crate) fn ffi<T>(&self, operation: &str, result: Result<T, String>) -> Result<T, String> {
        if let Err(error) = &result {
            if error == "cancelled" {
                return result;
            }
            self.write(
                "ERROR",
                "ffi",
                &format!("{operation}: {}", error_kind(error)),
            );
        }
        result
    }
    pub(crate) fn export(
        &self,
        ledger: &Ledger,
        directory: &Path,
        home: &Path,
        env: &Environment,
    ) -> Result<PathBuf, String> {
        let result = self.export_inner(Ok(ledger), directory, Some(home), env, None);
        self.ffi("export_diagnostics", result)
    }

    pub(crate) fn export_startup(
        &self,
        directory: &Path,
        home: Option<&Path>,
        env: &Environment,
        code: crate::startup_error::StartupCode,
        message: &str,
    ) -> Result<PathBuf, String> {
        use crate::startup_error::StartupCode;
        use crate::stats::{clock::Clock, ledger::ReadOpenError};

        if self.data.is_absolute() && directory.starts_with(&self.data) && !self.data.is_dir() {
            return Err(
                "export requires an existing data directory or an external destination".into(),
            );
        }
        let ledger = if self.data.is_absolute() {
            Ledger::open_read_only(&self.data.join("ledger.db"), Clock::System).and_then(|ledger| {
                ledger
                    .db
                    .execute_batch("BEGIN DEFERRED")
                    .map_err(|error| ReadOpenError::Unavailable(error.into()))?;
                ledger.check_read_version()?;
                Ok(ledger)
            })
        } else {
            Err(ReadOpenError::Missing)
        };
        let ledger = ledger.as_ref().map_err(|error| match error {
            ReadOpenError::Version(version) if *version > ledger::LEDGER_VERSION => {
                StartupCode::LedgerTooNew
            }
            ReadOpenError::Unavailable(error) => {
                StartupCode::from_message(&error.0).unwrap_or(StartupCode::StartupFailed)
            }
            _ => StartupCode::StartupFailed,
        });
        self.export_inner(ledger, directory, home, env, Some((code, message)))
    }

    fn export_inner(
        &self,
        ledger: Result<&Ledger, crate::startup_error::StartupCode>,
        directory: &Path,
        home: Option<&Path>,
        env: &Environment,
        startup: Option<(crate::startup_error::StartupCode, &str)>,
    ) -> Result<PathBuf, String> {
        if !directory.is_absolute() {
            return Err("export directory must be absolute".into());
        }
        let now = Local::now();
        let mut text = format!("Token Lens 诊断日志\n[应用]\ngenerated={}\nversion={}\ncommit={}\nos={}\ndata-dir={}\n", now.to_rfc3339(), env!("CARGO_PKG_VERSION"), option_env!("TOKEN_LENS_BUILD_COMMIT").unwrap_or("unavailable"), os_version(), self.data.display());
        let (schema, runs, statuses, unavailable) = match ledger {
            Ok(ledger) => {
                let read = || -> crate::stats::Result<_> {
                    let schema: i64 = ledger
                        .db
                        .query_row("PRAGMA user_version", [], |row| row.get(0))?;
                    let runs = ledger::rows(&ledger.db, "SELECT id,started_at,finished_at,status,attempted,inserted,updated,unchanged,rejected,counts,notes FROM ingest_runs ORDER BY id DESC LIMIT 10", &[])?;
                    Ok((Some(schema), runs, ledger.source_status()?, None))
                };
                match read() {
                    Ok(data) => data,
                    Err(error) if startup.is_some() => (
                        None,
                        Vec::new(),
                        Vec::new(),
                        Some(
                            crate::startup_error::StartupCode::from_message(&error.0)
                                .unwrap_or(crate::startup_error::StartupCode::StartupFailed),
                        ),
                    ),
                    Err(error) => return Err(error.to_string()),
                }
            }
            Err(code) => (None, Vec::new(), Vec::new(), Some(code)),
        };
        if let Some(schema) = schema {
            text.push_str(&format!("schema={schema}\n"));
        }
        if let Some((code, message)) = startup {
            let message = short_message(&self.sanitize_startup(message), 4096);
            text.push_str(&format!(
                "\n[启动失败]\ncode={}\nmessage={message}\n",
                code.as_str()
            ));
        }
        text.push_str("\n[最近同步]\n");
        if let Some(code) = unavailable {
            text.push_str(&format!("账本：无法打开（{}）\n", code.as_str()));
        }
        let mut discovered = home
            .map(|home| discovery::discover_with_env(home, env))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or_default();
        let discovered_files: Vec<_> = discovered
            .iter()
            .flat_map(|(_, files)| files.iter().cloned())
            .collect();
        for row in runs.iter().rev() {
            let duration = row["finished_at"]
                .as_i64()
                .zip(row["started_at"].as_i64())
                .map(|(end, start)| (end - start) * 1000);
            let counts: Value = row["counts"]
                .as_str()
                .and_then(|s| serde_json::from_str(s).ok())
                .unwrap_or(Value::Null);
            let counts = counts
                .as_object()
                .map(|m| {
                    m.iter()
                        .filter(|(key, value)| {
                            crate::diagnostics::COUNT_KEYS.contains(&key.as_str()) && value.is_u64()
                        })
                        .map(|(k, v)| format!("{k}={v}"))
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            let status = row["status"]
                .as_str()
                .filter(|s| {
                    [
                        "ok",
                        "failed",
                        "running",
                        "abandoned",
                        "completed_with_anomalies",
                    ]
                    .contains(s)
                })
                .unwrap_or("unknown");
            text.push_str(&format!("run id={} started={} finished={} status={status} durationMs={} attempted={} inserted={} updated={} unchanged={} rejected={} counts=[{counts}]\n", row["id"], run_time(&row["started_at"]), run_time(&row["finished_at"]), duration.map(|v| v.to_string()).unwrap_or_else(|| "unknown".into()), row["attempted"], row["inserted"], row["updated"], row["unchanged"], row["rejected"]));
            let notes: Vec<String> = row["notes"]
                .as_str()
                .and_then(|s| serde_json::from_str(s).ok())
                .unwrap_or_default();
            for (index, note) in notes.iter().enumerate() {
                text.push_str(&format!(
                    "  anomaly {}: {}\n",
                    index + 1,
                    safe_anomaly(note, &discovered_files)
                ));
            }
        }
        text.push_str("\n[来源]\n");
        for status in &statuses {
            if let Some(source) = status["source"].as_str() {
                if !discovered.iter().any(|(s, _)| s == source) {
                    discovered.push((source.into(), Vec::new()));
                }
            }
        }
        for (source, files) in discovered {
            let known = crate::stats::adapters::PARSER_REV
                .iter()
                .any(|s| s.0 == source);
            let label = if known {
                source.as_str()
            } else {
                "unknown-source"
            };
            let status = statuses.iter().find(|r| r["source"] == source);
            let latest = files
                .iter()
                .filter_map(|p| p.metadata().ok()?.modified().ok())
                .max()
                .map(|v| DateTime::<Local>::from(v).to_rfc3339())
                .unwrap_or_else(|| "unknown".into());
            let roots = home
                .map(|home| discovery::scan_roots(home, env, &source))
                .unwrap_or_default();
            text.push_str(&format!(
                "source={label} files={} latest-file-mtime={latest} records={} last-record={}\n",
                files.len(),
                status
                    .map(|r| r["records"].as_i64().unwrap_or(0))
                    .unwrap_or(0),
                status
                    .and_then(|r| r["last_observed_at"].as_str())
                    .filter(|s| chrono::DateTime::parse_from_rfc3339(s).is_ok())
                    .unwrap_or("unknown")
            ));
            for root in roots {
                text.push_str(&format!("  scan-root={}\n", root.display()));
            }
        }
        text.push_str("\n[运行日志]\n");
        let sanitize = |text: &str| {
            if startup.is_some() {
                self.sanitize_startup(text)
            } else {
                self.sanitize(text)
            }
        };
        let mut text = sanitize(&text);
        let mut budget = EXPORT_LIMIT.saturating_sub(text.len().saturating_add(256));
        let mut skipped = 0_u64;
        let _ = flush_runtime_log(LOG_FLUSH_TIMEOUT);
        let log_dir = self.data.join("logs");
        if (startup.is_none() || self.data.is_absolute()) && checked_existing_directory(&log_dir) {
            let entries = match fs::read_dir(&log_dir) {
                Ok(entries) => Some(entries),
                Err(_) if startup.is_some() => None,
                Err(error) => return Err(error.to_string()),
            };
            let mut files: Vec<_> = entries
                .into_iter()
                .flatten()
                .flatten()
                .filter(|e| {
                    ordinary(&e.path())
                        && log_date(&e.path()).is_some_and(|d| {
                            d >= now.date_naive() - Duration::days(6) && d <= now.date_naive()
                        })
                })
                .map(|e| e.path())
                .collect();
            files.sort();
            let mut tails = Vec::new();
            for path in files.into_iter().rev() {
                let length = match fs::metadata(&path) {
                    Ok(metadata) => metadata.len(),
                    Err(_) if startup.is_some() => continue,
                    Err(error) => return Err(error.to_string()),
                };
                if budget == 0 {
                    skipped = skipped.saturating_add(length);
                    continue;
                }
                let count = length.min(budget as u64) as usize;
                let (tail, omitted) = match fs::File::open(path)
                    .and_then(|mut file| read_log_tail(&mut file, length, budget))
                {
                    Ok(tail) => tail,
                    Err(_) if startup.is_some() => continue,
                    Err(error) => return Err(error.to_string()),
                };
                budget -= count;
                skipped = skipped.saturating_add(omitted);
                tails.push(String::from_utf8(tail).map_err(|e| e.to_string())?);
            }
            for tail in tails.into_iter().rev() {
                text.push_str(&tail);
            }
        }
        let text = sanitize(&text);
        let text = if skipped > 0 {
            format!("[截断：已省略最早的 {skipped} 字节，仅保留最新部分]\n{text}")
        } else {
            text
        };
        let text = truncate_export(text);
        fs::create_dir_all(directory).map_err(|e| e.to_string())?;
        let path = directory.join(format!(
            "token-lens-diagnostics-{}.txt",
            now.format("%Y%m%d-%H%M%S")
        ));
        // Same-second exports return an error instead of overwriting another report.
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        Ok(path)
    }

    fn sanitize_startup(&self, text: &str) -> String {
        let home = user_home();
        self.sanitize(&redact_home(text, home.as_deref()))
    }
}

pub(crate) fn user_home() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

pub(crate) const COUNT_KEYS: &[&str] = &[
    "read_failed",
    "bad_lines",
    "bad_fields",
    "bad_times",
    "zero_usage",
    "cross_file_copies",
    "relabeled",
    "reactivated",
    "replaced",
    "deactivated",
    "vanished",
    "rev_corrections",
    "cumulative_decrease",
];
fn checked_existing_directory(path: &Path) -> bool {
    path.is_dir()
        && path
            .ancestors()
            .all(|p| !fs::symlink_metadata(p).is_ok_and(|m| linked(&m)))
}
fn run_time(value: &Value) -> String {
    value
        .as_i64()
        .and_then(|v| DateTime::from_timestamp(v, 0))
        .map(|v| v.with_timezone(&Local).to_rfc3339())
        .unwrap_or_else(|| "unknown".into())
}

fn read_log_tail(
    reader: &mut (impl Read + Seek),
    length: u64,
    budget: usize,
) -> std::io::Result<(Vec<u8>, u64)> {
    let count = length.min(budget as u64) as usize;
    reader.seek(SeekFrom::Start(length - count as u64))?;
    let mut bytes = vec![0; count];
    reader.read_exact(&mut bytes)?;
    let trim = if length > count as u64 {
        bytes
            .iter()
            .take(3)
            .take_while(|c| **c & 0xc0 == 0x80)
            .count()
    } else {
        0
    };
    bytes.drain(..trim);
    Ok((bytes, length - count as u64 + trim as u64))
}
fn truncate_export(text: String) -> String {
    if text.len() <= EXPORT_LIMIT {
        return text;
    }
    // Keep the report sections while dropping the oldest runtime log bytes first.
    let boundary = text
        .find("[运行日志]\n")
        .map(|at| at + "[运行日志]\n".len())
        .unwrap_or(0);
    let preserved = if boundary + 256 < EXPORT_LIMIT {
        boundary
    } else {
        0
    };
    let prefix = &text[..preserved];
    let logs = &text[preserved..];
    let mut dropped = text.len() - EXPORT_LIMIT;
    loop {
        let header = format!("[截断：已省略最早的 {dropped} 字节，仅保留最新部分]\n");
        let required = text.len() + header.len() - EXPORT_LIMIT;
        if dropped < required {
            dropped = required;
            continue;
        }
        while !logs.is_char_boundary(dropped) {
            dropped += 1;
        }
        let header = format!("[截断：已省略最早的 {dropped} 字节，仅保留最新部分]\n");
        if text.len() - dropped + header.len() <= EXPORT_LIMIT {
            return header + prefix + &logs[dropped..];
        }
    }
}

#[cfg(test)]
mod tests;
