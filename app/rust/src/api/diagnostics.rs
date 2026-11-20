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
