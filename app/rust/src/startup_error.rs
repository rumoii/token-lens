use rusqlite::{Error as SqliteError, ErrorCode};
use std::{io, path::Path};

#[derive(Clone, Copy)]
pub(crate) enum StartupCode {
    AlreadyRunning,
    AppFilesMissing,
    DataDirDenied,
    DiskFull,
    LedgerCorrupt,
    LedgerTooNew,
    StartupFailed,
}

impl StartupCode {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::AlreadyRunning => "already_running",
            Self::AppFilesMissing => "app_files_missing",
            Self::DataDirDenied => "data_dir_denied",
            Self::DiskFull => "disk_full",
            Self::LedgerCorrupt => "ledger_corrupt",
            Self::LedgerTooNew => "ledger_too_new",
            Self::StartupFailed => "startup_failed",
        }
    }

    pub(crate) fn parse(code: &str) -> Option<Self> {
        [
            Self::AlreadyRunning,
            Self::AppFilesMissing,
            Self::DataDirDenied,
            Self::DiskFull,
            Self::LedgerCorrupt,
            Self::LedgerTooNew,
            Self::StartupFailed,
        ]
        .into_iter()
        .find(|value| value.as_str() == code)
    }

    pub(crate) fn from_message(message: &str) -> Option<Self> {
        let (code, _) = message.split_once(':')?;
        Self::parse(code)
    }

    pub(crate) fn message(self, detail: impl std::fmt::Display) -> String {
        format!("{}: {detail}", self.as_str())
    }

    pub(crate) fn fallback(message: String) -> String {
        if Self::from_message(&message).is_some() {
            message
        } else {
            Self::StartupFailed.message(message)
        }
    }

    pub(crate) fn from_io(error: &io::Error) -> Option<Self> {
        match error.kind() {
            io::ErrorKind::PermissionDenied => Some(Self::DataDirDenied),
            io::ErrorKind::StorageFull => Some(Self::DiskFull),
            _ if cfg!(windows) && error.raw_os_error() == Some(112) => Some(Self::DiskFull),
            _ => None,
        }
    }

    pub(crate) fn from_sqlite(
        error: &SqliteError,
        system_error: Option<&io::Error>,
    ) -> Option<Self> {
        match error.sqlite_error_code()? {
            ErrorCode::PermissionDenied | ErrorCode::ReadOnly => Some(Self::DataDirDenied),
            ErrorCode::DiskFull => Some(Self::DiskFull),
            ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase => Some(Self::LedgerCorrupt),
            ErrorCode::CannotOpen | ErrorCode::SystemIoFailure => {
                system_error.and_then(Self::from_io)
            }
            _ => None,
        }
    }
}

pub(crate) fn sqlite_open_error(
    error: SqliteError,
    path: &Path,
    writable: bool,
) -> crate::stats::Error {
    // rusqlite closes a failed connection before returning. Probe the existing
    // file for a typed OS error without creating or truncating anything.
    let system_error = if error.sqlite_error_code() == Some(ErrorCode::CannotOpen) {
        std::fs::OpenOptions::new()
            .read(true)
            .write(writable)
            .open(path)
            .err()
    } else {
        None
    };
    crate::stats::Error::sqlite(error, system_error.as_ref())
}
