use super::{Error, Result};
use rusqlite::{Connection, ErrorCode};
use std::path::Path;

pub struct SyncLock(Connection);

impl SyncLock {
    pub fn acquire(directory: &Path) -> Result<Self> {
        std::fs::create_dir_all(directory)?;
        if directory.join("sync.lock").exists() {
            return Err(Error(format!(
                "LEGACY_SYNC_LOCK: {}",
                directory.join("sync.lock").display()
            )));
        }
        let connection = Connection::open(directory.join("sync-lock.db"))?;
        connection.execute_batch("PRAGMA busy_timeout=0")?;
        if let Err(error) = connection.execute_batch("BEGIN IMMEDIATE") {
            if matches!(
                error.sqlite_error_code(),
                Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
            ) {
                return Err(Error("SYNC_BUSY: 已有同步或采集任务在执行中".into()));
            }
            return Err(error.into());
        }
        Ok(Self(connection))
    }
}

impl Drop for SyncLock {
    fn drop(&mut self) {
        let _ = self.0.execute_batch("ROLLBACK");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exclusion_release_and_legacy_refusal() {
        let directory = tempfile::tempdir().unwrap();
        let first = SyncLock::acquire(directory.path()).unwrap();
        assert!(SyncLock::acquire(directory.path())
            .err()
            .unwrap()
            .0
            .starts_with("SYNC_BUSY:"));
        drop(first);
        drop(SyncLock::acquire(directory.path()).unwrap());
        std::fs::write(directory.path().join("sync.lock"), "").unwrap();
        assert!(SyncLock::acquire(directory.path())
            .err()
            .unwrap()
            .0
            .starts_with("LEGACY_SYNC_LOCK:"));
    }
    #[test]
    fn node_and_rust_share_lock_and_killed_owner_releases() {
        use std::{
            io::{BufRead, BufReader, Write},
            process::{Command, Stdio},
        };
        let directory = tempfile::tempdir().unwrap();
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut child=Command::new("node").current_dir(root).args(["--input-type=module","-e","import { acquireSyncLock } from './src/core/sync-lock.js'; const lock=acquireSyncLock(process.argv[1]); console.log('ready'); process.stdin.resume(); process.stdin.on('data',()=>{lock.release();process.exit(0)});",directory.path().to_str().unwrap()]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let busy = SyncLock::acquire(directory.path()).err().map(|e| e.0);
        child.stdin.as_mut().unwrap().write_all(b"release").unwrap();
        let status = child.wait().unwrap();
        assert_eq!(line.trim(), "ready");
        assert!(status.success());
        assert!(busy.unwrap().starts_with("SYNC_BUSY:"));
        drop(SyncLock::acquire(directory.path()).unwrap());
        let mut child=Command::new("node").current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")).args(["--input-type=module","-e","import { acquireSyncLock } from './src/core/sync-lock.js'; acquireSyncLock(process.argv[1]); console.log('ready'); process.stdin.resume();",directory.path().to_str().unwrap()]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        line.clear();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(line.trim(), "ready");
        drop(SyncLock::acquire(directory.path()).unwrap());
    }
}
