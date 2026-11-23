use crate::{
    diagnostics::{self, RuntimeLog},
    startup_error::StartupCode,
    stats::discovery::Environment,
};
use std::path::{Path, PathBuf};

pub fn export_startup_diagnostics(
    data_dir: Option<String>,
    logs_home: Option<String>,
    directory: String,
    error_code: String,
    message: String,
) -> Result<String, String> {
    let data = data_dir.map(PathBuf::from).unwrap_or_default();
    if !data.as_os_str().is_empty() && !data.is_absolute() {
        return Err("data_dir must be an explicit absolute path".into());
    }
    let environment = Environment::process();
    let (home, environment) = if let Some(home) = logs_home {
        let home = PathBuf::from(home);
        if !home.is_absolute() {
            return Err("logs home must be absolute".into());
        }
        (Some(home), environment.preview())
    } else {
        (diagnostics::user_home(), environment)
    };
    let code = StartupCode::parse(&error_code).unwrap_or(StartupCode::StartupFailed);
    let log = RuntimeLog::new(&data, home.as_deref());
    log.export_startup(
        Path::new(&directory),
        home.as_deref(),
        &environment,
        code,
        &message,
    )
    .map(|path| path.to_string_lossy().into_owned())
}

pub fn startup_build_info() -> String {
    format!(
        "{} ({}) · {}",
        env!("CARGO_PKG_VERSION"),
        option_env!("TOKEN_LENS_BUILD_COMMIT").unwrap_or("unavailable"),
        diagnostics::os_version(),
    )
}

pub fn runtime_start(data_dir: String, logs_home: Option<String>) {
    if !Path::new(&data_dir).is_absolute() {
        return;
    }
    RuntimeLog::new(Path::new(&data_dir), logs_home.as_deref().map(Path::new)).write(
        "INFO",
        "app",
        &format!(
            "start version={} os={}",
            env!("CARGO_PKG_VERSION"),
            diagnostics::os_version()
        ),
    );
}

pub fn runtime_exit(data_dir: String, logs_home: Option<String>) {
    if !Path::new(&data_dir).is_absolute() {
        return;
    }
    RuntimeLog::new(Path::new(&data_dir), logs_home.as_deref().map(Path::new))
        .write("INFO", "app", "exit");
    let _ = diagnostics::flush_runtime_log(diagnostics::LOG_FLUSH_TIMEOUT);
}

pub fn write_runtime_error(
    data_dir: String,
    logs_home: Option<String>,
    error_type: String,
    message: String,
    stack: String,
) {
    if !Path::new(&data_dir).is_absolute() {
        return;
    }
    RuntimeLog::new(Path::new(&data_dir), logs_home.as_deref().map(Path::new)).flutter_error(
        &error_type,
        &message,
        &stack,
    );
}

pub fn write_runtime_log(
    data_dir: String,
    logs_home: Option<String>,
    level: String,
    module: String,
    message: String,
) {
    if !matches!(level.as_str(), "INFO" | "WARN")
        || module.is_empty()
        || module.len() > 32
        || !module
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return;
    }
    RuntimeLog::new(Path::new(&data_dir), logs_home.as_deref().map(Path::new))
        .write(&level, &module, &message);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flutter_runtime_log_accepts_info_and_warn_with_a_bounded_module() {
        let data = tempfile::tempdir().unwrap();
        let write = |level: &str, module: &str, message: &str| {
            write_runtime_log(
                data.path().to_str().unwrap().into(),
                None,
                level.into(),
                module.into(),
                message.into(),
            );
        };
        let long_module = "x".repeat(32);
        write("INFO", "mini-window", "started");
        write("WARN", &long_module, "waiting");
        write("ERROR", "mini-window", "rejected level");
        write("warn", "mini-window", "rejected spelling");
        write("INFO", "", "rejected empty module");
        write("INFO", "mini\nwindow", "rejected multiline module");
        write("INFO", &(long_module.clone() + "x"), "rejected long module");

        assert!(diagnostics::flush_runtime_log(
            std::time::Duration::from_secs(2)
        ));
        let mut logs = String::new();
        for entry in std::fs::read_dir(data.path().join("logs")).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|extension| extension.to_str()) == Some("log") {
                logs.push_str(&std::fs::read_to_string(path).unwrap());
            }
        }
        assert_eq!(logs.lines().count(), 2);
        assert!(logs.contains("INFO mini-window started"));
        assert!(logs.contains(&format!("WARN {long_module} waiting")));
    }
}
