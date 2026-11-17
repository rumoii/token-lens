use crate::diagnostics::{self, RuntimeLog};
use std::path::Path;

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
