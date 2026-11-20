pub(crate) mod adapters;
pub(crate) mod clock;
pub(crate) mod discovery;
pub(crate) mod ingest;
pub(crate) mod jscompat;
pub(crate) mod ledger;
pub(crate) mod lock;
pub(crate) mod output;
pub(crate) mod pricing;
pub(crate) mod service;
pub(crate) mod timezone;
#[cfg(test)]
mod timing_e4b_tests;
#[cfg(test)]
mod timing_fix1_tests;
#[cfg(test)]
mod timing_tests;

#[derive(Debug)]
pub struct Error(pub String);
impl Error {
    pub(crate) fn sqlite(e: rusqlite::Error, system_error: Option<&std::io::Error>) -> Self {
        use crate::startup_error::StartupCode;
        Self(match StartupCode::from_sqlite(&e, system_error) {
            Some(code) => code.message(e),
            None => e.to_string(),
        })
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for Error {}
impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Self::sqlite(e, None)
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        use crate::startup_error::StartupCode;
        Self(match StartupCode::from_io(&e) {
            Some(code) => code.message(e),
            None => e.to_string(),
        })
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self(e.to_string())
    }
}
pub type Result<T> = std::result::Result<T, Error>;
