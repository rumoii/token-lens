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
    use std::{
        io::{self, BufRead, BufReader, Read, Write},
        process::{Child, Command, Stdio},
        sync::mpsc,
        thread,
        time::Duration,
    };

    const LOCK_OWNER_DIR: &str = "TOKEN_LENS_TEST_LOCK_OWNER_DIR";

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

    fn spawn_lock_owner(directory: &Path) -> Child {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "stats::lock::tests::rust_processes_share_lock_and_killed_owner_releases",
                "--nocapture",
                "--format=terse",
            ])
            .env(LOCK_OWNER_DIR, directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (send_ready, ready) = mpsc::channel();
        thread::spawn(move || {
            let mut lines = BufReader::new(stdout).lines();
            if lines
                .by_ref()
                .map_while(std::result::Result::ok)
                .any(|line| line == "ready")
            {
                let _ = send_ready.send(());
            }
            // Keep reading until libtest has finished writing its output.
            drop(send_ready);
            for _ in lines {}
        });
        if let Err(error) = ready.recv_timeout(Duration::from_secs(10)) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("Lock owner did not report readiness: {error}");
        }
        child
    }

    #[test]
    fn rust_processes_share_lock_and_killed_owner_releases() {
        if let Some(directory) = std::env::var_os(LOCK_OWNER_DIR) {
            let _lock = SyncLock::acquire(Path::new(&directory)).unwrap();
            println!("ready");
            io::stdout().flush().unwrap();
            let _ = io::stdin().read(&mut [0]).unwrap();
            return;
        }

        let directory = tempfile::tempdir().unwrap();
        let mut child = spawn_lock_owner(directory.path());
        let busy = SyncLock::acquire(directory.path()).err().map(|e| e.0);
        drop(child.stdin.take());
        assert!(child.wait().unwrap().success());
        assert!(
            busy.as_deref()
                .is_some_and(|error| error.starts_with("SYNC_BUSY:")),
            "Expected SYNC_BUSY: while another process holds the lock, got {busy:?}"
        );
        drop(SyncLock::acquire(directory.path()).unwrap());

        let mut child = spawn_lock_owner(directory.path());
        child.kill().unwrap();
        assert!(!child.wait().unwrap().success());
        drop(SyncLock::acquire(directory.path()).unwrap());
    }
}
