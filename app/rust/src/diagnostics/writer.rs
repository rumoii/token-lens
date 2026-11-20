use super::{
    checked_directory, checked_existing_directory, log_date, ordinary, LIMIT_MARK, LOG_LIMIT,
};
use chrono::{DateTime, Duration, Local};
use fs2::FileExt;
use std::{
    collections::VecDeque,
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Condvar, Mutex,
    },
    thread,
    time::Duration as StdDuration,
};

pub(super) const QUEUE_LINES: usize = 4096;
pub(super) const QUEUE_BYTES: usize = 16 * 1024 * 1024;
const BATCH_LINES: usize = 128;

#[cfg(test)]
pub(super) static WRITER: Mutex<()> = Mutex::new(());

static QUEUE: Queue = Queue {
    state: Mutex::new(State {
        pending: VecDeque::new(),
        bytes: 0,
        accepted: 0,
        completed: 0,
        started: false,
    }),
    ready: Condvar::new(),
    drained: Condvar::new(),
    dropped: AtomicU64::new(0),
};

struct Queue {
    state: Mutex<State>,
    ready: Condvar,
    drained: Condvar,
    dropped: AtomicU64,
}

struct State {
    pending: VecDeque<LogLine>,
    bytes: usize,
    // In-flight lines retain their capacity until the worker finishes the batch.
    accepted: u64,
    completed: u64,
    started: bool,
}

pub(super) struct LogLine {
    pub(super) directory: PathBuf,
    pub(super) date: DateTime<Local>,
    // A line larger than a daily file needs only a limit marker.
    pub(super) text: Option<Box<str>>,
}

impl LogLine {
    fn bytes(&self) -> usize {
        self.directory.capacity() + self.text.as_ref().map_or(0, |text| text.len())
    }
}

pub(super) fn submit(line: LogLine) -> io::Result<()> {
    let mut state = QUEUE.state.lock().unwrap();
    let bytes = line.bytes();
    if state.accepted - state.completed >= QUEUE_LINES as u64 || bytes > QUEUE_BYTES - state.bytes {
        QUEUE.dropped.fetch_add(1, Ordering::Relaxed);
        return Ok(());
    }
    if !state.started {
        thread::Builder::new()
            .name("token-lens-log".into())
            .spawn(|| QUEUE.run())?;
        state.started = true;
    }
    state.pending.push_back(line);
    state.bytes += bytes;
    state.accepted += 1;
    drop(state);
    QUEUE.ready.notify_one();
    Ok(())
}

pub(super) fn flush(timeout: StdDuration) -> bool {
    let state = QUEUE.state.lock().unwrap();
    // Wait for the accepted prefix, even if producers keep submitting new lines.
    let target = state.accepted;
    let (state, _) = QUEUE
        .drained
        .wait_timeout_while(state, timeout, |state| state.completed < target)
        .unwrap();
    state.completed >= target
}

impl Queue {
    fn run(&self) {
        let mut batch = Vec::with_capacity(BATCH_LINES);
        loop {
            let state = self.state.lock().unwrap();
            let mut state = self
                .ready
                .wait_while(state, |state| state.pending.is_empty())
                .unwrap();
            let first = state.pending.pop_front().unwrap();
            while batch.len() + 1 < BATCH_LINES
                && state.pending.front().is_some_and(|next| {
                    next.directory == first.directory
                        && next.date.date_naive() == first.date.date_naive()
                })
            {
                batch.push(state.pending.pop_front().unwrap());
            }
            drop(state);

            let _ = write_batch(&first, &batch, &self.dropped);
            let count = 1 + batch.len() as u64;
            let bytes = first.bytes() + batch.iter().map(LogLine::bytes).sum::<usize>();
            drop(first);
            batch.clear();
            let mut state = self.state.lock().unwrap();
            state.completed += count;
            state.bytes -= bytes;
            self.drained.notify_all();
        }
    }
}

fn write_batch(first: &LogLine, rest: &[LogLine], dropped: &AtomicU64) -> io::Result<()> {
    #[cfg(test)]
    let _guard = WRITER.lock().unwrap_or_else(|error| error.into_inner());
    let directory = &first.directory;
    checked_directory(directory)?;
    let lock_path = directory.join(".writer.lock");
    if fs::symlink_metadata(&lock_path).is_ok() && !ordinary(&lock_path) {
        return Ok(());
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)?;
    loop {
        match FileExt::try_lock_exclusive(&lock) {
            Ok(()) => break,
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.raw_os_error() == fs2::lock_contended_error().raw_os_error() =>
            {
                thread::sleep(StdDuration::from_millis(5));
            }
            Err(error) => return Err(error),
        }
    }
    // A contended lock can outlive the directory check done before opening it.
    if !checked_existing_directory(directory) || !ordinary(&lock_path) {
        return Ok(());
    }
    // Retention runs under the same cross-process lock as the write.
    let oldest = first.date.date_naive() - Duration::days(6);
    for entry in fs::read_dir(directory)?.flatten() {
        if ordinary(&entry.path()) && log_date(&entry.path()).is_some_and(|day| day < oldest) {
            let _ = fs::remove_file(entry.path());
        }
    }
    let path = directory.join(format!("token-lens-{}.log", first.date.format("%Y-%m-%d")));
    if fs::symlink_metadata(&path).is_ok() && !ordinary(&path) {
        return Ok(());
    }
    let mut log = DailyLog::open(&path)?;
    for line in std::iter::once(first).chain(rest) {
        log.append(line, dropped)?;
        if log.capped {
            break;
        }
    }
    Ok(())
}

struct DailyLog {
    file: File,
    length: u64,
    capped: bool,
}

fn ends_with_limit_marker(text: &str) -> bool {
    text.lines().last().is_some_and(|line| {
        line.split_whitespace()
            .skip(3)
            .eq(["WARN", "runtime", LIMIT_MARK])
    })
}

impl DailyLog {
    fn open(path: &Path) -> io::Result<Self> {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        let length = file.metadata()?.len();
        file.seek(SeekFrom::End(-(length.min(256) as i64)))?;
        let mut tail = Vec::new();
        file.read_to_end(&mut tail)?;
        let capped = length <= LOG_LIMIT && ends_with_limit_marker(&String::from_utf8_lossy(&tail));
        Ok(Self {
            file,
            length,
            capped,
        })
    }

    fn append(&mut self, line: &LogLine, dropped: &AtomicU64) -> io::Result<()> {
        if self.capped {
            return Ok(());
        }
        let timestamp = line.date.format("%Y-%m-%d %H:%M:%S%.3f %:z");
        let marker = format!("{timestamp} WARN runtime {LIMIT_MARK}\n");
        let capacity = LOG_LIMIT - marker.len() as u64 - 1;
        let Some(text) = line
            .text
            .as_deref()
            .filter(|text| self.length + text.len() as u64 <= capacity)
        else {
            self.mark_limit(capacity, &marker)?;
            self.capped = true;
            return Ok(());
        };
        self.file.write_all(text.as_bytes())?;
        self.length += text.len() as u64;
        self.capped = ends_with_limit_marker(text);

        let count = dropped.load(Ordering::Relaxed);
        if count > 0 && !self.capped {
            let warning = format!(
                "{timestamp} WARN runtime dropped {count} runtime log lines (queue full)\n"
            );
            if self.length + warning.len() as u64 <= capacity {
                self.file.write_all(warning.as_bytes())?;
                self.length += warning.len() as u64;
                // Only this worker subtracts. Drops concurrent with the write remain pending.
                dropped.fetch_sub(count, Ordering::Relaxed);
            }
        }
        Ok(())
    }

    fn mark_limit(&mut self, capacity: u64, marker: &str) -> io::Result<()> {
        if self.length > capacity {
            let mut cutoff = capacity;
            let mut byte = [0];
            while cutoff > 0 {
                self.file.seek(SeekFrom::Start(cutoff))?;
                self.file.read_exact(&mut byte)?;
                if byte[0] & 0xc0 != 0x80 {
                    break;
                }
                cutoff -= 1;
            }
            self.file.set_len(cutoff)?;
            self.length = cutoff;
        }
        let mut last = *b"\n";
        if self.length > 0 {
            self.file.seek(SeekFrom::End(-1))?;
            self.file.read_exact(&mut last)?;
        }
        if last[0] != b'\n' {
            self.file.write_all(b"\n")?;
        }
        self.file.write_all(marker.as_bytes())
    }
}
