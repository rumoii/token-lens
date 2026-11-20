use crate::{
    api::stats::StatsClient,
    stats::{
        clock::Clock,
        ledger::ReadOpenError,
        output::{self, Scope},
        timezone, Error,
    },
};
use chrono::{DateTime, Datelike, Days, Local, NaiveDate, Utc};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::OsString,
    io::{self, Write},
    path::{Path, PathBuf},
};

const HELP: &str = "token-lens-cli [--data-dir ABSOLUTE] [--project-paths] [--pretty] COMMAND
  status | sources | sync
  summary [--compare]
  breakdown --by tool|model|project|day|hour|month
  sessions [--sort recent|cost|tokens] [--limit 1..200] [--cursor CURSOR]
  session --tool SOURCE --id SESSION
  --help | --version
summary, breakdown and sessions accept --period today|week|month|all|yesterday|lastWeek|lastMonth|last7|last30
or --from YYYY-MM-DD --to YYYY-MM-DD, and --tool, --model and --project filters.";

#[derive(Debug)]
enum Failure {
    Usage(&'static str),
    Read(ReadOpenError),
    Busy,
    Failed,
}

impl Failure {
    fn response(self) -> (u8, Value) {
        let (exit, code, message) = match self {
            Self::Usage(message) => (1, "usage", message.to_owned()),
            Self::Read(error @ ReadOpenError::Missing) => (2, "no_ledger", error.to_string()),
            Self::Read(error @ ReadOpenError::Version(_)) => {
                (2, "ledger_version", error.to_string())
            }
            Self::Busy => (
                3,
                "sync_busy",
                "A sync or another ledger operation holds the sync lock.".into(),
            ),
            Self::Read(ReadOpenError::Unavailable(_)) | Self::Failed => (
                4,
                "failed",
                "Token Lens could not complete the command.".into(),
            ),
        };
        (
            exit,
            json!({"format_version":1,"error":{"code":code,"message":message}}),
        )
    }
}

impl From<ReadOpenError> for Failure {
    fn from(error: ReadOpenError) -> Self {
        Self::Read(error)
    }
}
impl From<Error> for Failure {
    fn from(_: Error) -> Self {
        Self::Failed
    }
}
type CliResult<T> = Result<T, Failure>;

#[derive(Default)]
struct Args {
    command: String,
    values: HashMap<String, String>,
    data_dir: Option<PathBuf>,
    pretty: bool,
    paths: bool,
    compare: bool,
}

impl Args {
    fn parse(mut args: impl Iterator<Item = OsString>) -> CliResult<Self> {
        let mut parsed = Self::default();
        while let Some(arg) = args.next() {
            let arg = arg
                .into_string()
                .map_err(|_| Failure::Usage("Arguments must be valid Unicode."))?;
            match arg.as_str() {
                "--pretty" if !parsed.pretty => parsed.pretty = true,
                "--project-paths" if !parsed.paths => parsed.paths = true,
                "--compare" if !parsed.compare => parsed.compare = true,
                "--data-dir" if parsed.data_dir.is_none() => {
                    let path = args
                        .next()
                        .map(PathBuf::from)
                        .filter(|path| path.is_absolute())
                        .ok_or(Failure::Usage("--data-dir requires an absolute path."))?;
                    parsed.data_dir = Some(path);
                }
                "--period" | "--from" | "--to" | "--tool" | "--model" | "--project" | "--by"
                | "--sort" | "--limit" | "--cursor" | "--id"
                    if !parsed.values.contains_key(&arg) =>
                {
                    let value = args
                        .next()
                        .and_then(|value| value.into_string().ok())
                        .filter(|value| !value.trim().is_empty() && !value.starts_with("--"))
                        .ok_or(Failure::Usage("An option is missing its value."))?;
                    parsed.values.insert(arg, value);
                }
                "status" | "summary" | "breakdown" | "sessions" | "session" | "sources"
                | "sync" | "--version" | "--help"
                    if parsed.command.is_empty() =>
                {
                    parsed.command = arg
                }
                _ => {
                    return Err(Failure::Usage(
                        "Unknown or repeated argument. Run --help for usage.",
                    ))
                }
            }
        }
        if parsed.command.is_empty() {
            return Err(Failure::Usage("Specify a command. Run --help for usage."));
        }
        let range = [
            "--period",
            "--from",
            "--to",
            "--tool",
            "--model",
            "--project",
        ];
        for key in parsed.values.keys().map(String::as_str) {
            let valid = match parsed.command.as_str() {
                "summary" => range.contains(&key),
                "breakdown" => range.contains(&key) || key == "--by",
                "sessions" => {
                    range.contains(&key) || ["--sort", "--limit", "--cursor"].contains(&key)
                }
                "session" => matches!(key, "--tool" | "--id"),
                _ => false,
            };
            if !valid {
                return Err(Failure::Usage(
                    "An option is incompatible with the command.",
                ));
            }
        }
        if parsed.compare && parsed.command != "summary" {
            return Err(Failure::Usage("--compare is only available with summary."));
        }
        Ok(parsed)
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    fn scope(&self, now: DateTime<Utc>, timezone: &str) -> CliResult<(Scope, Option<Scope>)> {
        let local = now.with_timezone(&Local);
        let today = local.date_naive();
        let (period, from, to) = match (self.get("--period"), self.get("--from"), self.get("--to"))
        {
            (None, Some(start), Some(end)) => {
                let (start, end) = (parse_day(start)?, parse_day(end)?);
                if start > end {
                    return Err(Failure::Usage("--from must not be later than --to."));
                }
                ("custom", Some(start), Some(end))
            }
            (period, None, None) => {
                let period = period.unwrap_or("month");
                let days_ago = |days| today.checked_sub_days(Days::new(days));
                let weekday = u64::from(today.weekday().num_days_from_monday());
                let (from, to) = match period {
                    "today" => (Some(today), Some(today)),
                    "week" => (days_ago(weekday), Some(today)),
                    "month" => (today.with_day(1), Some(today)),
                    "all" => (None, None),
                    "yesterday" => (days_ago(1), days_ago(1)),
                    "lastWeek" => (days_ago(weekday + 7), days_ago(weekday + 1)),
                    "lastMonth" => {
                        let end = today.with_day(1).and_then(|day| day.pred_opt());
                        (end.and_then(|day| day.with_day(1)), end)
                    }
                    "last7" => (days_ago(6), Some(today)),
                    "last30" => (days_ago(29), Some(today)),
                    _ => {
                        return Err(Failure::Usage(
                            "--period requires today, week, month, all, yesterday, lastWeek, lastMonth, last7 or last30.",
                        ))
                    }
                };
                if period != "all" && (from.is_none() || to.is_none()) {
                    return Err(Failure::Usage("Period is outside the supported calendar."));
                }
                (period, from, to)
            }
            _ => {
                return Err(Failure::Usage(
                    "Supply both --from and --to, or use --period.",
                ))
            }
        };
        let offset = local.offset().local_minus_utc() / 60;
        let make_scope = |period: &str, from: Option<NaiveDate>, to: Option<NaiveDate>| Scope {
            period: period.into(),
            timezone: timezone.into(),
            paths: self.paths,
            filter: json!({
                "from":from.map(|day| day.to_string()),"to":to.map(|day| day.to_string()),
                "source":self.get("--tool"),"model":self.get("--model"),"project":self.get("--project"),
                "offsetMinutes":offset
            }),
        };
        let scope = make_scope(period, from, to);
        let prior = if self.compare {
            let (Some(from), Some(to)) = (from, to) else {
                return Err(Failure::Usage("--compare requires a bounded period."));
            };
            let (previous_from, previous_to) = previous_range(period, from, to)
                .filter(|(from, _)| from.year() >= 0)
                .ok_or(Failure::Usage(
                    "Previous period is outside the supported calendar.",
                ))?;
            Some(make_scope(period, Some(previous_from), Some(previous_to)))
        } else {
            None
        };
        Ok((scope, prior))
    }
}

pub(crate) fn calendar_day(text: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .ok()
        .filter(|date| date.year() >= 0 && text.len() == 10 && date.to_string() == text)
}

fn parse_day(text: &str) -> CliResult<NaiveDate> {
    calendar_day(text).ok_or(Failure::Usage("Dates must be valid YYYY-MM-DD values."))
}

fn previous_range(period: &str, from: NaiveDate, to: NaiveDate) -> Option<(NaiveDate, NaiveDate)> {
    if matches!(period, "month" | "lastMonth") {
        let last = from.pred_opt()?;
        let end = if period == "month" {
            last.with_day(last.day().min(to.day()))?
        } else {
            last
        };
        return Some((last.with_day(1)?, end));
    }
    let days = match period {
        "week" => 7,
        "today" => 1,
        _ => u64::try_from((to - from).num_days() + 1).ok()?,
    };
    Some((
        from.checked_sub_days(Days::new(days))?,
        to.checked_sub_days(Days::new(days))?,
    ))
}

const WINDOWS_COMPANY: &str = "Token Lens";
const WINDOWS_PRODUCT: &str = "Token Lens";
const MAC_BUNDLE: &str = "io.github.rumoii.token-lens";

fn platform_directory(windows: bool, root: &Path) -> PathBuf {
    if windows {
        root.join(WINDOWS_COMPANY)
            .join(WINDOWS_PRODUCT)
            .join("data")
    } else {
        root.join("Library")
            .join("Application Support")
            .join(MAC_BUNDLE)
            .join("data")
    }
}

fn data_directory(explicit: Option<PathBuf>) -> CliResult<PathBuf> {
    if let Some(path) =
        explicit.or_else(|| std::env::var_os("TOKEN_LENS_PREVIEW_DATA_DIR").map(PathBuf::from))
    {
        return if path.is_absolute() {
            Ok(path)
        } else {
            Err(Failure::Usage("The data directory must be absolute."))
        };
    }
    if cfg!(debug_assertions) {
        return Err(Failure::Usage(
            "Debug builds require --data-dir or TOKEN_LENS_PREVIEW_DATA_DIR.",
        ));
    }
    let home_key = if cfg!(windows) { "APPDATA" } else { "HOME" };
    if !cfg!(any(windows, target_os = "macos")) {
        return Err(Failure::Usage("Supply --data-dir on this platform."));
    }
    let home = std::env::var_os(home_key)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or(Failure::Failed)?;
    Ok(platform_directory(cfg!(windows), &home))
}

fn clock() -> CliResult<Clock> {
    if cfg!(debug_assertions) {
        if let Ok(text) = std::env::var("TOKEN_LENS_CLI_TEST_NOW") {
            let time = DateTime::parse_from_rfc3339(&text)
                .map_err(|_| Failure::Usage("Invalid debug clock."))?;
            return Ok(Clock::Fixed(time.timestamp_millis()));
        }
    }
    Ok(Clock::System)
}

fn execute(args: Args) -> CliResult<(Value, bool)> {
    let clock = clock()?;
    let now = DateTime::from_timestamp_millis(clock.millis()).ok_or(Failure::Failed)?;
    let receipt_clock = Clock::Fixed(now.timestamp_millis());
    let command = args.command.as_str();
    if matches!(command, "--help" | "--version") {
        let (command, data) = if command == "--help" {
            ("help", json!({"usage":HELP}))
        } else {
            ("version", json!({"version":env!("CARGO_PKG_VERSION")}))
        };
        return Ok((
            output::envelope(
                command,
                &receipt_clock,
                &Value::Null,
                output::static_query("UTC"),
                data,
            ),
            args.pretty,
        ));
    }
    let timezone = timezone::system_timezone()?;
    let (scope, prior) = if matches!(command, "summary" | "breakdown" | "sessions") {
        let (scope, prior) = args.scope(now, &timezone)?;
        (Some(scope), prior)
    } else {
        (None, None)
    };
    let by = args.get("--by").unwrap_or("");
    if command == "breakdown" && !output::GROUPS.contains(&by) {
        return Err(Failure::Usage(
            "breakdown requires --by tool, model, project, day, hour or month.",
        ));
    }
    let sort = args.get("--sort").unwrap_or("recent");
    if !matches!(sort, "recent" | "tokens" | "cost") {
        return Err(Failure::Usage("--sort requires recent, cost or tokens."));
    }
    let limit = args
        .get("--limit")
        .unwrap_or("20")
        .parse::<usize>()
        .ok()
        .filter(|limit| (1..=200).contains(limit))
        .ok_or(Failure::Usage("--limit must be between 1 and 200."))?;
    let after = if let Some(cursor) = args.get("--cursor") {
        let owner = output::cursor_scope(scope.as_ref().unwrap(), sort);
        Some(
            output::parse_cursor(cursor, &owner, sort)
                .ok_or(Failure::Usage("Invalid cursor for this query."))?,
        )
    } else {
        None
    };
    let tool = args.get("--tool").unwrap_or("");
    let id = args.get("--id").unwrap_or("");
    if command == "session" && (tool.is_empty() || id.is_empty()) {
        return Err(Failure::Usage("session requires both --tool and --id."));
    }
    let data = data_directory(args.data_dir.clone())?;
    let document = if command == "sync" {
        let home = std::env::var("TOKEN_LENS_PREVIEW_HOME")
            .ok()
            .filter(|home| !home.is_empty());
        if cfg!(debug_assertions) && home.is_none() {
            return Err(Failure::Usage(
                "Debug sync requires TOKEN_LENS_PREVIEW_HOME.",
            ));
        }
        if home
            .as_ref()
            .is_some_and(|home| !Path::new(home).is_absolute())
        {
            return Err(Failure::Usage("TOKEN_LENS_PREVIEW_HOME must be absolute."));
        }
        let client =
            StatsClient::for_cli(data.to_str().ok_or(Failure::Failed)?.into(), home, clock)
                .map_err(|_| Failure::Failed)?;
        let sync = client.sync_triggered("cli".into()).map_err(|error| {
            if error.starts_with("SYNC_BUSY:") || error.starts_with("LEGACY_SYNC_LOCK:") {
                Failure::Busy
            } else {
                Failure::Failed
            }
        })?;
        let completed_clock = Clock::Fixed(clock_after_sync(&receipt_clock));
        output::read(&data, completed_clock, |ledger| {
            output::sync_result(ledger, &timezone, output::sync_data(&sync))
        })?
    } else {
        output::read(&data, receipt_clock, |ledger| match command {
            "status" => output::status(ledger, &timezone),
            "sources" => output::sources(ledger, &timezone),
            "summary" => output::summary(ledger, scope.as_ref().unwrap(), prior.as_ref()),
            "breakdown" => output::breakdown(ledger, scope.as_ref().unwrap(), by),
            "sessions" => {
                output::sessions(ledger, scope.as_ref().unwrap(), sort, limit, after.as_ref())
            }
            "session" => output::session(ledger, &timezone, tool, id, args.paths),
            _ => unreachable!("argument parser validated the command"),
        })?
    };
    Ok((document, args.pretty))
}

fn clock_after_sync(started: &Clock) -> i64 {
    if cfg!(debug_assertions) && std::env::var_os("TOKEN_LENS_CLI_TEST_NOW").is_some() {
        started.millis()
    } else {
        Clock::System.millis()
    }
}

pub fn run(args: impl Iterator<Item = OsString>) -> u8 {
    let result = Args::parse(args)
        .and_then(execute)
        .and_then(|(doc, pretty)| Ok(output::encode(&doc, pretty)?));
    match result {
        Ok(bytes) => {
            if io::stdout().lock().write_all(&bytes).is_ok() {
                0
            } else {
                4
            }
        }
        Err(error) => {
            let (exit, doc) = error.response();
            let _ = writeln!(io::stderr().lock(), "{doc}");
            exit
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn shortcut_bounds_match_the_app_calendar() {
        let cases = [
            (
                "lastWeek",
                "2026-11-16",
                "2026-11-09",
                "2026-11-15",
                "2026-11-02",
                "2026-11-08",
            ),
            (
                "lastMonth",
                "2026-03-31",
                "2026-02-01",
                "2026-02-28",
                "2026-01-01",
                "2026-01-31",
            ),
            (
                "lastMonth",
                "2026-01-01",
                "2025-12-01",
                "2025-12-31",
                "2025-11-01",
                "2025-11-30",
            ),
            (
                "yesterday",
                "2026-01-01",
                "2025-12-31",
                "2025-12-31",
                "2025-12-30",
                "2025-12-30",
            ),
            (
                "last7",
                "2026-04-02",
                "2026-03-27",
                "2026-04-02",
                "2026-03-20",
                "2026-03-26",
            ),
            (
                "last30",
                "2024-03-01",
                "2024-02-01",
                "2024-03-01",
                "2024-01-02",
                "2024-01-31",
            ),
        ];
        for (period, today, from, to, prior_from, prior_to) in cases {
            let day = parse_day(today).unwrap();
            let now = Local
                .with_ymd_and_hms(day.year(), day.month(), day.day(), 12, 0, 0)
                .unwrap()
                .to_utc();
            let args = Args::parse(
                ["summary", "--period", period, "--compare"]
                    .into_iter()
                    .map(OsString::from),
            )
            .unwrap();
            let (current, previous) = args
                .scope(now, "UTC")
                .unwrap_or_else(|error| panic!("{period}: {error:?}"));
            for (scope, start, end) in [
                (current, from, to),
                (previous.unwrap(), prior_from, prior_to),
            ] {
                assert_eq!(scope.period, period);
                assert_eq!(scope.filter["from"], start, "{period} on {today}");
                assert_eq!(scope.filter["to"], end, "{period} on {today}");
            }
        }
    }

    #[test]
    fn platform_path_matches_the_desktop_manifests() {
        let windows = include_str!("../../windows/runner/Runner.rc");
        let rc = |name| {
            windows
                .lines()
                .find_map(|line| {
                    let mut fields = line.split('"');
                    (fields.next()?.trim() == "VALUE" && fields.next()? == name)
                        .then(|| fields.nth(1))
                        .flatten()
                })
                .unwrap()
        };
        let mac = include_str!("../../macos/Runner/Configs/AppInfo.xcconfig");
        let bundle = mac
            .lines()
            .find_map(|line| line.strip_prefix("PRODUCT_BUNDLE_IDENTIFIER = "))
            .unwrap();
        let root = Path::new("fixture");
        assert_eq!(
            platform_directory(true, root),
            root.join(rc("CompanyName"))
                .join(rc("ProductName"))
                .join("data")
        );
        assert_eq!(
            platform_directory(false, root),
            root.join("Library/Application Support")
                .join(bundle)
                .join("data")
        );
    }

    #[test]
    fn prior_bounds_match_the_app_calendar_and_custom_span() {
        let cases = [
            (
                "today",
                "2026-11-19",
                "2026-11-19",
                "2026-11-18",
                "2026-11-18",
            ),
            (
                "week",
                "2026-11-16",
                "2026-11-19",
                "2026-11-09",
                "2026-11-12",
            ),
            (
                "month",
                "2026-03-01",
                "2026-03-31",
                "2026-02-01",
                "2026-02-28",
            ),
            (
                "month",
                "2024-03-01",
                "2024-03-31",
                "2024-02-01",
                "2024-02-29",
            ),
            (
                "month",
                "2026-01-01",
                "2026-01-08",
                "2025-12-01",
                "2025-12-08",
            ),
            (
                "custom",
                "2026-11-17",
                "2026-11-19",
                "2026-11-14",
                "2026-11-16",
            ),
        ];
        for (period, start, end, prior_start, prior_end) in cases {
            let day = |text| parse_day(text).unwrap();
            assert_eq!(
                previous_range(period, day(start), day(end)),
                Some((day(prior_start), day(prior_end)))
            );
        }
    }
}
