use super::*;
use crate::stats::ledger::rows;
use chrono::{DateTime, SecondsFormat};
use std::{fs, io::Write, path::PathBuf};

const START_MS: i64 = 1768478400000;
const SESSION: &str = "oracle-session";
const TARGET: &str = "resp_oracle_replacement_target";

struct Oracle {
    executor: SyncExecutor,
    _root: tempfile::TempDir,
    home: PathBuf,
    data: [PathBuf; 3],
    round: i64,
    revisions: Option<Revisions>,
    reread_next: bool,
}

impl Oracle {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        fs::create_dir(&home).unwrap();
        let data = ["cached", "no-cache", "persistent"].map(|side| root.path().join(side));
        for dir in &data {
            let ledger = Ledger::open(&dir.join("ledger.db"), Clock::Fixed(START_MS)).unwrap();
            // SQLite checks the production default using the INSERT's own wall clock, then
            // records the round's fixed UTC second. Updates still use the real writer.
            ledger
                .db
                .execute_batch(
                    "CREATE TRIGGER oracle_ingested_at AFTER INSERT ON usage_records
                 BEGIN
                   SELECT CASE WHEN NEW.ingested_at IS NOT unixepoch()
                     THEN RAISE(ABORT, 'usage INSERT must default to the current UTC second') END;
                   UPDATE usage_records SET ingested_at = (
                     SELECT started_at FROM ingest_runs
                     WHERE status = 'running' ORDER BY id DESC LIMIT 1
                   ) WHERE id = NEW.id;
                 END;",
                )
                .unwrap();
        }
        Self {
            executor: SyncExecutor::default(),
            _root: root,
            home,
            data,
            round: 0,
            revisions: None,
            reread_next: false,
        }
    }

    fn write(&self, path: &Path, bytes: impl AsRef<[u8]>) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn ledger(&self, side: usize) -> Ledger {
        Ledger::open(&self.data[side].join("ledger.db"), Clock::Fixed(self.now())).unwrap()
    }

    fn now(&self) -> i64 {
        START_MS + self.round * 1000
    }

    fn compare_round(&mut self, label: &str) -> Value {
        self.compare_profiled_round(label).0
    }

    fn compare_profiled_round(&mut self, label: &str) -> (Value, Value) {
        self.compare_all(label).0
    }

    fn compare_all(&mut self, label: &str) -> ((Value, Value), (Value, Value)) {
        self.round += 1;
        let context = format!("{label}, round {}", self.round);
        let run = |side: usize, no_cache| {
            sync_profiled(
                &self.data[side],
                &self.home,
                &Environment::default(),
                Clock::Fixed(self.now()),
                &LocalZone::Fixed(0),
                &AtomicBool::new(false),
                SyncOptions {
                    revisions: self.revisions,
                    ..SyncOptions::new(no_cache)
                },
            )
            .unwrap_or_else(|error| panic!("{context}, no_cache={no_cache}: {error}"))
        };
        // The same immutable input tree is read by both passes, including its absolute paths.
        let (cached, phases) = run(0, false);
        let (replay, replay_phases) = run(1, true);
        let (persistent, persistent_phases) = sync_profiled(
            &self.data[2],
            &self.home,
            &Environment::default(),
            Clock::Fixed(START_MS + self.round * 1000),
            &LocalZone::Fixed(0),
            &AtomicBool::new(false),
            SyncOptions {
                executor: Some(&mut self.executor),
                revisions: self.revisions,
                no_cache: std::mem::take(&mut self.reread_next),
                ..Default::default()
            },
        )
        .unwrap_or_else(|error| panic!("persistent {context}: {error}"));
        assert_eq!(replay["cachedFiles"], 0, "{context}");
        assert_eq!(replay["skippedFiles"], 0, "{context}");
        assert_eq!(replay_phases["writeSkippedFiles"], 0, "{context}");
        assert_eq!(
            replay_phases["writeTransactions"], replay["fileCount"],
            "{context}"
        );
        assert_eq!(replay["parsedFiles"], replay["fileCount"], "{context}");
        assert_eq!(cached["fileCount"], replay["fileCount"], "{context}");
        for result in [&cached, &replay, &persistent] {
            assert_eq!(result["counts"]["read_failed"], 0, "{context}");
            assert_eq!(result["rejected"], 0, "{context}");
        }
        for ordinary in [&cached, &persistent] {
            assert_eq!(ordinary["fileCount"], replay["fileCount"], "{context}");
            if ordinary["skippedFiles"] != 0 {
                continue;
            }
            for key in [
                "attempted",
                "inserted",
                "updated",
                "unchanged",
                "rejected",
                "counts",
            ] {
                assert_eq!(ordinary[key], replay[key], "{context}: {key}");
            }
            assert_eq!(ordinary["anomalies"], replay["anomalies"], "{context}");
        }
        compare_ledgers(&self.ledger(0), &self.ledger(1), &context);
        compare_ledgers(
            &self.ledger(2),
            &self.ledger(1),
            &format!("persistent {context}"),
        );
        ((cached, phases), (persistent, persistent_phases))
    }

    fn other_instance_sync(&mut self) {
        self.round += 1;
        for data in &self.data {
            sync_profiled(
                data,
                &self.home,
                &Environment::default(),
                Clock::Fixed(self.now()),
                &LocalZone::Fixed(0),
                &AtomicBool::new(false),
                SyncOptions {
                    revisions: self.revisions,
                    ..SyncOptions::new(true)
                },
            )
            .unwrap();
        }
    }

    fn set_manual_price(&self, price: usize) {
        for (side, data) in self.data.iter().enumerate() {
            crate::stats::pricing::store::save_manual(
                data,
                &self.ledger(side),
                &json!({"model":"oracle-random-price","currency":"USD","input":price,"output":0})
                    .to_string(),
            )
            .unwrap();
        }
    }

    fn cancel_round(&mut self) {
        self.round += 1;
        let now = self.now();
        for (side, data) in self.data.iter().enumerate() {
            let result = sync_profiled(
                data,
                &self.home,
                &Environment::default(),
                Clock::Fixed(now),
                &LocalZone::Fixed(0),
                &AtomicBool::new(true),
                SyncOptions {
                    executor: (side == 2).then_some(&mut self.executor),
                    revisions: self.revisions,
                    ..SyncOptions::new(side == 1)
                },
            );
            assert_eq!(result.unwrap_err().0, "cancelled");
        }
        assert!(self.executor.retained.is_none());
    }
}

fn select(ledger: &Ledger, sql: &str) -> Vec<Value> {
    rows(&ledger.db, sql, &[]).unwrap()
}

fn compare_ledgers(cached: &Ledger, replay: &Ledger, context: &str) {
    for (table, order) in [("usage_records", "id"), ("usage_timings", "record_key")] {
        let sql = format!("SELECT * FROM {table} ORDER BY {order}");
        let left = select(cached, &sql);
        let right = select(replay, &sql);
        assert_eq!(left.len(), right.len(), "{context}: {table} row count");
        for (left, right) in left.iter().zip(&right) {
            let columns = left.as_object().unwrap();
            assert_eq!(
                columns.len(),
                right.as_object().unwrap().len(),
                "{context}: {table} columns"
            );
            for (column, value) in columns {
                assert_eq!(
                    Some(value),
                    right.get(column),
                    "{context}: {table} row {} ({}) column {column} (cached vs no_cache)",
                    left[order],
                    left["record_key"]
                );
            }
        }
    }
    let filter = json!({});
    assert_eq!(
        cached.totals(&filter).unwrap(),
        replay.totals(&filter).unwrap(),
        "{context}: totals"
    );
    for by in ["source", "model", "project"] {
        let groups = |ledger: &Ledger| {
            let mut rows = ledger.breakdown(by, &filter).unwrap();
            rows.sort_by_key(|r| r["bucket"].to_string());
            rows
        };
        assert_eq!(
            groups(cached),
            groups(replay),
            "{context}: breakdown by {by}"
        );
    }
    let groups = |ledger: &Ledger| {
        let mut rows = ledger.grouped("source", "model", &filter).unwrap();
        rows.sort_by_key(|r| (r["outer_key"].to_string(), r["inner_key"].to_string()));
        rows
    };
    assert_eq!(
        groups(cached),
        groups(replay),
        "{context}: source/model groups"
    );
}

#[derive(Clone, Copy, Debug)]
enum Source {
    Codex,
    Claude,
}

impl Source {
    fn path(self, home: &Path, slot: usize, compressed: bool) -> PathBuf {
        match self {
            Self::Codex => {
                let extension = if compressed { "jsonl.zst" } else { "jsonl" };
                home.join(".codex")
                    .join("sessions")
                    .join(format!("rollout-{slot}.{extension}"))
            }
            Self::Claude => home
                .join(".claude")
                .join("projects")
                .join(format!("{slot}.jsonl")),
        }
    }
}

#[derive(Clone, Copy)]
struct Event {
    id: usize,
    minute: i64,
    tokens: usize,
}

fn time(minute: i64, offset_ms: i64) -> String {
    DateTime::from_timestamp_millis(START_MS + minute * 60_000 + offset_ms)
        .unwrap()
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn codex_usage(minute: i64, identity: Value, tokens: usize) -> Value {
    let mut payload = identity;
    payload["session_id"] = json!(SESSION);
    payload["usage"] = json!({"model":"gpt-5.3-codex","input_tokens":tokens,
        "cached_input_tokens":1,"output_tokens":2});
    json!({"type":"token_usage_record","timestamp":time(minute, 1000),"payload":payload})
}

fn jsonl(lines: impl IntoIterator<Item = Value>) -> Vec<u8> {
    lines
        .into_iter()
        .flat_map(|line| format!("{line}\n").into_bytes())
        .collect()
}

fn encode(source: Source, events: &[Event]) -> Vec<u8> {
    jsonl(events.iter().flat_map(|event| {
        let Event { id, minute, tokens } = *event;
        match source {
            Source::Codex => [
                json!({"type":"event_msg","timestamp":time(minute, 0),"payload":{"type":"task_started"}}),
                json!({"type":"event_msg","timestamp":time(minute, 600),"payload":{
                    "type":"item_completed","item":{"type":"AgentMessage"},
                    "started_at_ms":START_MS + minute * 60_000 + 400,
                    "completed_at_ms":START_MS + minute * 60_000 + 600}}),
                codex_usage(minute, json!({"response_id":format!("resp_oracle_event_{id:08x}")}), tokens),
            ],
            Source::Claude => [
                json!({"type":"api-request","timestamp":time(minute, 0),"id":format!("req_{id}")}),
                json!({"type":"assistant","apiBlockIndex":0,"timestamp":time(minute, 600),
                    "requestRef":format!("req_{id}"),"thinkingDurationMs":200,
                    "message":{"id":format!("msg_{id}"),"content":[{"type":"thinking"}]}}),
                json!({"type":"assistant","sessionId":SESSION,"timestamp":time(minute, 1000),
                    "requestRef":format!("req_{id}"),
                    "message":{"id":format!("msg_{id}"),"model":"claude-sonnet-5-5",
                               "stop_reason":"end_turn","usage":{"input_tokens":tokens,"output_tokens":2}}}),
            ],
        }
    }))
}

fn raw_zstd(bytes: &[u8]) -> Vec<u8> {
    // Standard Zstandard frame with one raw block, including for an empty file.
    assert!(bytes.len() <= 128 * 1024);
    let size = bytes.len() as u32;
    let mut frame = vec![0x28, 0xb5, 0x2f, 0xfd, 0xa0];
    frame.extend_from_slice(&size.to_le_bytes());
    frame.extend_from_slice(&((size << 3) | 1).to_le_bytes()[..3]);
    frame.extend_from_slice(bytes);
    frame
}

#[derive(Clone, Copy, Debug)]
enum Action {
    Append,
    Rewrite,
    Truncate,
    Delete,
    Restore,
    CopyRecord,
    Move,
    ToggleZstd,
    Unchanged,
}

impl Action {
    const ALL: [Self; 9] = [
        Self::Append,
        Self::Rewrite,
        Self::Truncate,
        Self::Delete,
        Self::Restore,
        Self::CopyRecord,
        Self::Move,
        Self::ToggleZstd,
        Self::Unchanged,
    ];
}

struct Random(u64);

impl Random {
    fn index(&mut self, len: usize) -> usize {
        // xorshift64 with nonzero seeds. Use identical choices on 32- and 64-bit hosts.
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % len as u64) as usize
    }

    fn choose<T: Copy>(&mut self, choices: &[T]) -> Option<T> {
        (!choices.is_empty()).then(|| choices[self.index(choices.len())])
    }
}

struct Document {
    events: Vec<Event>,
    compressed: bool,
}

struct History {
    source: Source,
    files: [Option<Document>; 5],
    deleted: Vec<(usize, Document, Vec<u8>)>,
    next_id: usize,
}

impl History {
    fn new(source: Source, oracle: &Oracle) -> Self {
        let mut history = Self {
            source,
            files: std::array::from_fn(|_| None),
            deleted: Vec::new(),
            next_id: 1,
        };
        for slot in 0..3 {
            let events = vec![history.new_event(), history.new_event()];
            history.files[slot] = Some(Document {
                events,
                compressed: false,
            });
            history.save(oracle, slot);
        }
        history
    }

    fn new_event(&mut self) -> Event {
        let id = self.next_id;
        self.next_id += 1;
        Event {
            id,
            minute: id as i64,
            tokens: 10 + id,
        }
    }

    fn save(&self, oracle: &Oracle, slot: usize) {
        let file = self.files[slot].as_ref().unwrap();
        let path = self.source.path(&oracle.home, slot, file.compressed);
        let mut plain = encode(self.source, &file.events);
        let frame_overhead = if file.compressed { 12 } else { 0 };
        // Force a size change even on filesystems with coarse mtime precision.
        if fs::metadata(&path).is_ok_and(|old| old.len() == (plain.len() + frame_overhead) as u64) {
            plain.push(b'\n');
        }
        let bytes = if file.compressed {
            raw_zstd(&plain)
        } else {
            plain
        };
        oracle.write(&path, bytes);
    }

    fn append(&mut self, oracle: &Oracle, slot: usize, event: Event) {
        let file = self.files[slot].as_mut().unwrap();
        let path = self.source.path(&oracle.home, slot, file.compressed);
        let mut bytes = encode(self.source, &[event]);
        if file.compressed {
            bytes = raw_zstd(&bytes);
        }
        fs::OpenOptions::new()
            .append(true)
            .open(path)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
        file.events.push(event);
    }

    fn apply(&mut self, oracle: &Oracle, rng: &mut Random, action: Action) -> bool {
        let mut present = Vec::new();
        let mut nonempty = Vec::new();
        let mut vacant = Vec::new();
        for (slot, file) in self.files.iter().enumerate() {
            if let Some(file) = file {
                present.push(slot);
                if !file.events.is_empty() {
                    nonempty.push(slot);
                }
            } else {
                vacant.push(slot);
            }
        }
        match action {
            Action::Append => {
                let slot = rng.choose(&present).unwrap();
                let event = self.new_event();
                self.append(oracle, slot, event);
            }
            Action::Rewrite | Action::Truncate => {
                let Some(slot) = rng.choose(&nonempty) else {
                    return false;
                };
                let file = self.files[slot].as_mut().unwrap();
                if matches!(action, Action::Rewrite) {
                    let index = rng.index(file.events.len());
                    file.events[index].tokens += 1 + rng.index(13);
                } else {
                    // A truncated input is literally zero bytes, including when it was .zst.
                    fs::write(self.source.path(&oracle.home, slot, file.compressed), []).unwrap();
                    file.events.clear();
                    return true;
                }
                self.save(oracle, slot);
            }
            Action::Delete => {
                if present.len() < 2 {
                    return false;
                }
                let slot = rng.choose(&present).unwrap();
                let file = self.files[slot].take().unwrap();
                let path = self.source.path(&oracle.home, slot, file.compressed);
                let bytes = fs::read(&path).unwrap();
                fs::remove_file(&path).unwrap();
                self.deleted.push((slot, file, bytes));
            }
            Action::Restore => {
                let eligible: Vec<_> = self
                    .deleted
                    .iter()
                    .enumerate()
                    .filter_map(|(index, (slot, _, _))| vacant.contains(slot).then_some(index))
                    .collect();
                let Some(index) = rng.choose(&eligible) else {
                    return false;
                };
                let (slot, file, bytes) = self.deleted.remove(index);
                oracle.write(
                    &self.source.path(&oracle.home, slot, file.compressed),
                    bytes,
                );
                self.files[slot] = Some(file);
            }
            Action::CopyRecord => {
                let mut copies = Vec::new();
                for from in nonempty {
                    for &to in present.iter().filter(|&&to| to != from) {
                        let source = &self.files[from].as_ref().unwrap().events;
                        let target = &self.files[to].as_ref().unwrap().events;
                        // Repeating a long ID within one file can advance revision on every
                        // replay. Only copy to a different file that does not have this ID.
                        for event in source {
                            if !target.iter().any(|other| other.id == event.id) {
                                copies.push((to, *event));
                            }
                        }
                    }
                }
                let Some((to, event)) = rng.choose(&copies) else {
                    return false;
                };
                self.append(oracle, to, event);
            }
            Action::Move => {
                let Some(to) = rng.choose(&vacant) else {
                    return false;
                };
                let from = rng.choose(&present).unwrap();
                let file = self.files[from].take().unwrap();
                fs::rename(
                    self.source.path(&oracle.home, from, file.compressed),
                    self.source.path(&oracle.home, to, file.compressed),
                )
                .unwrap();
                self.files[to] = Some(file);
            }
            Action::ToggleZstd => {
                let slot = rng.choose(&present).unwrap();
                let file = self.files[slot].as_mut().unwrap();
                fs::remove_file(self.source.path(&oracle.home, slot, file.compressed)).unwrap();
                file.compressed = !file.compressed;
                self.save(oracle, slot);
            }
            Action::Unchanged => (),
        }
        true
    }
}

#[test]
fn seeded_mutations_match_full_replay() {
    let mut covered = [[0; Action::ALL.len()]; 2];
    for seed in [0x9029_a635, 0x1737_d2b1, 0xc05c_4857] {
        let mut rng = Random(seed);
        let mut oracle = Oracle::new();
        let mut histories =
            [Source::Codex, Source::Claude].map(|source| History::new(source, &oracle));
        oracle.compare_round(&format!("seed {seed:#x} (initial)"));
        let ledger = oracle.ledger(0);
        assert_eq!(
            select(
                &ledger,
                "SELECT source, count(*) FROM usage_timings GROUP BY source"
            )
            .len(),
            2
        );
        assert_eq!(
            select(
                &ledger,
                "SELECT DISTINCT source FROM usage_records WHERE cost_micros IS NOT NULL"
            )
            .len(),
            2
        );
        for _ in 0..36 {
            let mut actions = Vec::new();
            for (index, history) in histories.iter_mut().enumerate() {
                // An independent action per source. Claude only discovers plain JSONL.
                let action = Action::ALL[rng.index(Action::ALL.len())];
                let action = match (history.source, action) {
                    (Source::Claude, Action::ToggleZstd) => Action::Unchanged,
                    _ => action,
                };
                let applied = history.apply(&oracle, &mut rng, action);
                covered[index][action as usize] += usize::from(applied);
                actions.push((history.source, action, applied));
            }
            // The model never writes different bytes behind an unchanged size and mtime.
            oracle.compare_round(&format!("seed {seed:#x}, {actions:?}"));
        }
    }
    for (index, source) in [Source::Codex, Source::Claude].into_iter().enumerate() {
        for (action, hits) in Action::ALL.into_iter().zip(covered[index]) {
            if index == 0 || !matches!(action, Action::ToggleZstd) {
                assert!(hits > 0, "{source:?} did not exercise {action:?}");
            }
        }
    }
}

#[test]
fn seeded_executor_invalidations_match_full_replay() {
    let mut covered = [0; 7];
    for seed in [0x9029_a635, 0x1737_d2b1, 0xc05c_4857] {
        let mut rng = Random(seed);
        let mut lifecycle = Random(seed ^ 0x824a_8a59);
        let mut oracle = Oracle::new();
        let mut histories =
            [Source::Codex, Source::Claude].map(|source| History::new(source, &oracle));
        let mut unpriced = codex_usage(0, json!({"response_id":"resp_oracle_random_price"}), 31);
        unpriced["payload"]["usage"]["model"] = json!("oracle-random-price");
        oracle.write(
            &Source::Codex.path(&oracle.home, 99, false),
            jsonl([unpriced]),
        );
        oracle.compare_round("initial executor state");
        for round in 0..36 {
            let action = lifecycle.index(14);
            if action < covered.len() {
                covered[action] += 1;
            }
            match action {
                0 => oracle.executor = SyncExecutor::default(),
                1 => oracle.other_instance_sync(),
                2 => oracle.cancel_round(),
                3 | 4 => {
                    let mut revisions = oracle.revisions.unwrap_or(Revisions {
                        usage: Some(adapters::parser_rev("codex")),
                        timing: adapters::timing_rev("codex"),
                    });
                    if action == 3 {
                        revisions.usage = revisions.usage.map(|rev| rev + 1);
                    } else {
                        revisions.timing = revisions.timing.map(|rev| rev + 1);
                    }
                    oracle.revisions = Some(revisions);
                }
                5 => oracle.set_manual_price(round + 1),
                6 => oracle.reread_next = true,
                _ => {}
            }
            for history in &mut histories {
                let action = Action::ALL[rng.index(Action::ALL.len())];
                if !matches!(
                    (history.source, action),
                    (Source::Claude, Action::ToggleZstd)
                ) {
                    history.apply(&oracle, &mut rng, action);
                }
            }
            let (_, (_, phases)) = oracle.compare_all(&format!(
                "seed {seed:#x}, round {round}, lifecycle action {action}"
            ));
            if action <= 6 {
                assert_eq!(phases["indexHits"], 0);
            }
            if action == 6 {
                assert!(oracle.executor.retained.is_none());
            }
        }
    }
    assert!(covered.into_iter().all(|count| count > 0), "{covered:?}");
}

fn owner(oracle: &Oracle, id: usize) -> Value {
    let ledger = oracle.ledger(0);
    ledger
        .db
        .query_row(
            "SELECT source_file FROM usage_records WHERE record_key = ? AND active = 1",
            [format!("codex|{SESSION}|resp_oracle_event_{id:08x}")],
            |row| row.get::<_, String>(0),
        )
        .map(Value::String)
        .unwrap()
}

fn add_independent_files(oracle: &Oracle, source: Source) {
    for slot in 20..28 {
        oracle.write(
            &source.path(&oracle.home, slot, false),
            encode(
                source,
                &[Event {
                    id: slot,
                    minute: slot as i64,
                    tokens: 20,
                }],
            ),
        );
    }
}

#[test]
fn oversized_index_falls_back_to_full_replay_and_idle_skip() {
    let mut oracle = Oracle::new();
    let source = Source::Codex;
    let file = source.path(&oracle.home, 0, false);
    let event = |id| Event {
        id,
        minute: id as i64,
        tokens: 10,
    };
    oracle.executor.memory_limit = Some(1);
    oracle.write(&file, encode(source, &[event(1)]));
    let (_, (_, cold)) = oracle.compare_all("index exceeds the cap");
    assert_eq!(cold["indexMemoryBytes"], 0);
    assert_eq!(cold["indexRebuilds"], 0);

    let (_, (receipt, idle)) = oracle.compare_all("fallback skips an idle source");
    assert_eq!(receipt["skippedFiles"], 1);
    assert_eq!(idle["cacheDecodedBytes"], 0);

    oracle.write(&file, encode(source, &[event(1), event(2)]));
    let (_, (receipt, hot)) = oracle.compare_all("fallback processes changed content");
    assert_eq!(receipt["inserted"], 1);
    assert_eq!(hot["indexMemoryBytes"], 0);
}

#[test]
fn oversized_index_disables_later_sources_in_the_same_round() {
    let mut oracle = Oracle::new();
    let event = |id| Event {
        id,
        minute: id as i64,
        tokens: 10,
    };
    for source in [Source::Claude, Source::Codex] {
        for id in 0..4 {
            oracle.write(
                &source.path(&oracle.home, id, false),
                encode(source, &[event(id)]),
            );
        }
    }
    let (_, (_, cold)) = oracle.compare_all("both sources build an index");
    assert_eq!(cold["indexRebuilds"], 2);

    oracle.executor.memory_limit = Some(1);
    for source in [Source::Claude, Source::Codex] {
        let active = source.path(&oracle.home, 0, false);
        oracle.write(&active, encode(source, &[event(0), event(4)]));
    }
    let (_, (receipt, hot)) = oracle.compare_all("the first source exhausts the budget");
    assert_eq!(hot["indexHits"], 3);
    assert_eq!(receipt["cachedFiles"], 3);
    assert_eq!(hot["indexMemoryBytes"], 0);
}

#[test]
fn persistent_hot_round_only_decodes_an_affected_cache_hit() {
    for source in [Source::Codex, Source::Claude] {
        let mut oracle = Oracle::new();
        let event = |id| Event {
            id,
            minute: id as i64,
            tokens: 20,
        };
        for file in 0..32 {
            let events = if file == 1 {
                vec![event(1), event(2)]
            } else {
                vec![event(file + 1)]
            };
            oracle.write(
                &source.path(&oracle.home, file, false),
                encode(source, &events),
            );
        }
        oracle.compare_round("build the index with one copy group");
        let path = source.path(&oracle.home, 1, false);
        let bytes: i64 = oracle
            .ledger(2)
            .db
            .query_row(
                "SELECT length(payload) FROM ingest_files WHERE path=?",
                [path.to_str().unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        oracle.write(
            &source.path(&oracle.home, 0, false),
            encode(source, &[event(1), event(33)]),
        );
        let (_, (result, phases)) = oracle.compare_all("change only one copy group");
        assert_eq!(phases["cacheDecodedBytes"], bytes, "{source:?}");
        assert_eq!(phases["affectedFiles"], 2, "{source:?}");
        assert_eq!(phases["indexHits"], 30, "{source:?}");
        assert_eq!(result["attempted"], 33, "{source:?}");
        assert_eq!(result["unchanged"], 32, "{source:?}");
        assert_eq!(result["counts"]["cross_file_copies"], 1, "{source:?}");
    }
}

#[test]
fn omitted_copy_group_preserves_cached_notes_and_copy_counts() {
    let mut oracle = Oracle::new();
    let [owner, copy, hot] = [0, 1, 2].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let event = |id| Event {
        id,
        minute: id as i64,
        tokens: 20,
    };
    oracle.write(&owner, encode(Source::Codex, &[event(1)]));
    let mut copied = encode(Source::Codex, &[event(1)]);
    copied.extend_from_slice(b"{bad json\n");
    oracle.write(&copy, copied);
    oracle.write(&hot, encode(Source::Codex, &[event(2)]));
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("certify a stable copy group with a parse note");
    oracle.write(&hot, encode(Source::Codex, &[event(2), event(3)]));
    let (_, (result, phases)) = oracle.compare_all("omit the complete copy group");
    assert_eq!(phases["affectedFiles"], 1);
    assert_eq!(phases["indexHits"], 10);
    assert_eq!(phases["cacheDecodedBytes"], 0);
    assert_eq!(result["counts"]["bad_lines"], 1);
    assert_eq!(result["counts"]["cross_file_copies"], 1);
}

#[test]
fn copy_owner_disappears_and_the_remaining_file_takes_ownership() {
    let mut oracle = Oracle::new();
    let [a, b] = [0, 1].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let shared = Event {
        id: 1,
        minute: 10,
        tokens: 20,
    };
    oracle.write(&a, encode(Source::Codex, &[shared]));
    oracle.write(
        &b,
        encode(
            Source::Codex,
            &[
                shared,
                Event {
                    id: 2,
                    minute: 12,
                    ..shared
                },
            ],
        ),
    );
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("partial copy");
    assert_eq!(owner(&oracle, 1), json!(a));
    fs::remove_file(&a).unwrap();
    let (_, (_, phases)) = oracle.compare_all("copy owner removed");
    assert_eq!(phases["affectedFiles"], 1);
    assert_eq!(phases["indexHits"], 8);
    assert_eq!(owner(&oracle, 1), json!(b));
}

#[test]
fn changing_the_earliest_time_reassigns_a_shared_record() {
    let mut oracle = Oracle::new();
    let [a, b] = [0, 1].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let shared = Event {
        id: 1,
        minute: 10,
        tokens: 20,
    };
    let anchor = Event {
        id: 2,
        minute: 2,
        ..shared
    };
    oracle.write(&a, encode(Source::Codex, &[anchor, shared]));
    oracle.write(
        &b,
        encode(
            Source::Codex,
            &[
                Event {
                    id: 3,
                    minute: 5,
                    ..shared
                },
                shared,
            ],
        ),
    );
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("A starts earlier");
    assert_eq!(owner(&oracle, 1), json!(a));
    let mut bytes = encode(
        Source::Codex,
        &[
            Event {
                minute: 7,
                ..anchor
            },
            shared,
        ],
    );
    bytes.push(b'\n');
    oracle.write(&a, bytes);
    let (_, (_, phases)) = oracle.compare_all("B starts earlier");
    assert_eq!(phases["affectedFiles"], 2);
    assert_eq!(phases["indexHits"], 8);
    assert_eq!(owner(&oracle, 1), json!(b));
}

#[test]
fn historical_owner_that_no_longer_produces_the_key_joins_the_closure() {
    let mut oracle = Oracle::new();
    let [a, b] = [0, 1].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let first = Event {
        id: 1,
        minute: 0,
        tokens: 20,
    };
    let second = Event {
        id: 2,
        minute: 5,
        tokens: 20,
    };
    oracle.write(&a, encode(Source::Codex, &[first]));
    oracle.write(&b, encode(Source::Codex, &[second]));
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("original actual owner");
    oracle.write(&a, []);
    oracle.compare_round("empty output leaves the actual owner in the ledger");
    assert_eq!(owner(&oracle, 1), json!(a));
    oracle.write(&b, encode(Source::Codex, &[first, second]));
    let (_, (_, phases)) = oracle.compare_all("another file starts producing the old key");
    assert_eq!(phases["affectedFiles"], 2);
    assert_eq!(phases["cachedFiles"], 1);
    assert_eq!(phases["indexHits"], 8);
    assert_eq!(owner(&oracle, 1), json!(b));
}

#[test]
fn one_file_transitively_joins_two_copy_groups() {
    let mut oracle = Oracle::new();
    let [a, bridge, c] = [0, 1, 2].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let first = Event {
        id: 1,
        minute: 1,
        tokens: 20,
    };
    let second = Event {
        id: 2,
        minute: 2,
        tokens: 20,
    };
    oracle.write(&a, encode(Source::Codex, &[first]));
    oracle.write(&bridge, encode(Source::Codex, &[first, second]));
    oracle.write(&c, encode(Source::Codex, &[second]));
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("two copy groups with one shared file");
    oracle.write(
        &a,
        encode(
            Source::Codex,
            &[Event {
                tokens: 200,
                ..first
            }],
        ),
    );
    let (_, (result, phases)) = oracle.compare_all("change one end of the connected copy groups");
    assert_eq!(phases["affectedFiles"], 3);
    assert_eq!(phases["cachedFiles"], 2);
    assert_eq!(phases["indexHits"], 8);
    assert_eq!(result["counts"]["cross_file_copies"], 2);
}

#[test]
fn claude_chained_replacements_use_original_write_order() {
    let mut oracle = Oracle::new();
    let inputs = [
        ("head", "tail"),
        ("middle", "head|tail"),
        ("end", "middle|head|tail"),
    ];
    let record = |(session, key), tokens| {
        json!({
            "type":"assistant", "sessionId":session, "timestamp":time(0, 1000),
            "message":{"id":key,"model":"claude-sonnet-5-5","stop_reason":"end_turn",
                       "usage":{"input_tokens":tokens,"output_tokens":2}}
        })
    };
    for (slot, identity) in inputs.into_iter().enumerate() {
        oracle.write(
            &Source::Claude.path(&oracle.home, slot, false),
            jsonl([record(identity, 20)]),
        );
    }
    add_independent_files(&oracle, Source::Claude);
    oracle.compare_round("build an index with two delayed replacements");
    oracle.write(
        &Source::Claude.path(&oracle.home, 0, false),
        jsonl([record(inputs[0], 200)]),
    );
    let (_, (_, phases)) = oracle.compare_all("settle the delayed replacement chain");
    assert_eq!(phases["affectedFiles"], 3);
    assert_eq!(phases["cachedFiles"], 2);
    assert_eq!(phases["indexHits"], 8);
    assert_eq!(
        select(
            &oracle.ledger(2),
            "SELECT record_key,active FROM usage_records WHERE record_key LIKE '%tail' ORDER BY id"
        ),
        [
            json!({"record_key":"claude|tail","active":1}),
            json!({"record_key":"claude|head|tail","active":0}),
            json!({"record_key":"claude|middle|head|tail","active":1}),
        ]
    );
}

#[test]
fn committed_prefix_cancellation_discards_the_index_and_recovers_pending() {
    let mut oracle = Oracle::new();
    let first = Source::Codex.path(&oracle.home, 0, false);
    let event = |id| Event {
        id,
        minute: id as i64,
        tokens: 20,
    };
    oracle.write(&first, encode(Source::Codex, &[event(1)]));
    add_independent_files(&oracle, Source::Codex);
    oracle.compare_round("before cancellation");
    oracle.write(&first, encode(Source::Codex, &[event(1), event(2)]));
    oracle.round += 1;
    let now = oracle.now();
    for (side, data) in oracle.data.iter().enumerate() {
        let cancel = AtomicBool::new(false);
        let cancel_after_commit = || cancel.store(true, Ordering::Release);
        let result = sync_profiled(
            data,
            &oracle.home,
            &Environment::default(),
            Clock::Fixed(now),
            &LocalZone::Fixed(0),
            &cancel,
            SyncOptions {
                executor: (side == 2).then_some(&mut oracle.executor),
                after_commit: Some(&cancel_after_commit),
                ..SyncOptions::new(side == 1)
            },
        );
        assert_eq!(result.unwrap_err().0, "cancelled");
        assert_eq!(
            select(
                &oracle.ledger(side),
                "SELECT source FROM ingest_pending_sources"
            ),
            [json!({"source":"codex"})]
        );
    }
    assert!(oracle.executor.retained.is_none());
    compare_ledgers(
        &oracle.ledger(2),
        &oracle.ledger(1),
        "cancelled committed prefix",
    );
    let (_, (_, phases)) = oracle.compare_all("full replay from the same committed prefix");
    assert_eq!(phases["indexHits"], 0);
    assert_eq!(phases["indexRebuilds"], 1);
    assert!(select(&oracle.ledger(2), "SELECT * FROM ingest_pending_sources").is_empty());
}

fn replacement(oracle: &Oracle, declaration_first: bool) {
    let [first, second] = [0, 1].map(|slot| Source::Codex.path(&oracle.home, slot, false));
    let target = codex_usage(0, json!({"response_id": TARGET}), 20);
    let declaration = codex_usage(1, json!({"turn_id": TARGET}), 40);
    let (a, b) = if declaration_first {
        (declaration, target)
    } else {
        (target, declaration)
    };
    oracle.write(&first, jsonl([a]));
    oracle.write(&second, jsonl([b]));
}

fn assert_replacement(oracle: &Oracle, pending: bool) {
    let rows = select(
        &oracle.ledger(0),
        "SELECT id,active,superseded_by FROM usage_records WHERE session_id='oracle-session' ORDER BY id",
    );
    if pending {
        assert_eq!(
            rows,
            [
                json!({"id":1,"active":1,"superseded_by":null}),
                json!({"id":2,"active":1,"superseded_by":null}),
            ]
        );
    } else {
        assert_eq!(rows.iter().filter(|r| r["active"] == 0).count(), 1);
        let retired = rows.iter().find(|r| r["active"] == 0).unwrap();
        let active = rows.iter().find(|r| r["active"] == 1).unwrap();
        assert_eq!(retired["superseded_by"], active["id"]);
    }
}

#[test]
fn claude_idle_skips_its_source_and_hot_skips_unchanged_files() {
    let mut oracle = Oracle::new();
    let files = [0, 1, 2].map(|slot| Source::Claude.path(&oracle.home, slot, false));
    for (slot, file) in files.iter().enumerate() {
        oracle.write(
            file,
            encode(
                Source::Claude,
                &[Event {
                    id: slot,
                    minute: slot as i64,
                    tokens: 20,
                }],
            ),
        );
    }
    oracle.compare_round("Claude cold");
    let (idle, idle_phases) = oracle.compare_profiled_round("Claude idle");

    oracle.write(
        &files[0],
        encode(
            Source::Claude,
            &[Event {
                id: 0,
                minute: 0,
                tokens: 45,
            }],
        ),
    );
    let (hot, phases) = oracle.compare_profiled_round("Claude hot");
    assert_eq!(hot["updated"], 1);
    assert_eq!(hot["unchanged"], 2);
    assert_eq!(hot["cachedFiles"], 2);
    assert_eq!(phases["writeTransactions"], 1);
    assert_eq!(phases["writeSkippedFiles"], 2);
    assert_eq!(idle["skippedFiles"], 3);
    assert_eq!(idle["attempted"], 0);
    assert_eq!(idle_phases["writeTransactions"], 0);
    assert_eq!(idle_phases["cachePayloadReadNs"], 0);
}

fn claude_with_pending_replacement() -> (Oracle, PathBuf) {
    let mut oracle = Oracle::new();
    oracle.write(
        &Source::Claude.path(&oracle.home, 0, false),
        encode(
            Source::Claude,
            &[Event {
                id: 1,
                minute: 0,
                tokens: 40,
            }],
        ),
    );
    oracle.compare_round("Claude declaration without target");
    let target = Source::Claude.path(&oracle.home, 1, false);
    oracle.write(
        &target,
        jsonl([json!({
            "type":"assistant","sessionId":SESSION,"timestamp":time(1, 1000),
            "uuid":format!("{SESSION}|msg_1"),
            "message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":20}}
        })]),
    );
    oracle.compare_round("Claude target is first inserted after the declaration");
    assert_replacement(&oracle, true);
    (oracle, target)
}

#[test]
fn claude_replays_when_a_later_file_first_produces_a_replacement_target() {
    let (mut oracle, _) = claude_with_pending_replacement();
    let (replay, phases) = oracle.compare_profiled_round("Claude pending target is retired");
    assert_eq!(replay["counts"]["replaced"], 1);
    assert_eq!(phases["writeTransactions"], 2);
    assert_replacement(&oracle, false);
    let (idle, phases) = oracle.compare_profiled_round("Claude replacement is settled");
    assert_eq!(idle["skippedFiles"], 2);
    assert_eq!(phases["writeTransactions"], 0);
    assert_replacement(&oracle, false);
}

#[test]
fn claude_replays_for_an_active_historical_target_and_skips_after_retirement() {
    let (mut oracle, target) = claude_with_pending_replacement();
    fs::remove_file(&target).unwrap();
    let (replay, phases) = oracle.compare_profiled_round("removed file leaves an active target");
    assert_eq!(replay["counts"]["replaced"], 1);
    assert_eq!(phases["writeTransactions"], 1);
    assert_replacement(&oracle, false);

    oracle.write(
        &Source::Claude.path(&oracle.home, 2, false),
        encode(
            Source::Claude,
            &[Event {
                id: 2,
                minute: 2,
                tokens: 20,
            }],
        ),
    );
    let (hot, phases) = oracle.compare_profiled_round("historical target is now inactive");
    assert_eq!(hot["counts"]["replaced"], 0);
    assert_eq!(phases["writeTransactions"], 1);
    assert_eq!(phases["writeSkippedFiles"], 1);
}

fn gemini_snapshot(oracle: &Oracle, file: &str, session: &str, minute: i64) {
    oracle.write(
        &oracle.home.join(".gemini/sessions").join(file),
        json!({
            "sessionId":session,"startTime":time(minute, 0),"model":"gemini-2.5-pro",
            "usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":10}
        })
        .to_string(),
    );
}

#[test]
fn gemini_idle_skips_multiple_files_with_distinct_snapshot_keys() {
    let mut oracle = Oracle::new();
    gemini_snapshot(&oracle, "a.json", "first", 0);
    gemini_snapshot(&oracle, "b.json", "second", 1);
    oracle.compare_round("Gemini distinct snapshots cold");
    let (idle, phases) = oracle.compare_profiled_round("Gemini distinct snapshots idle");
    assert_eq!(idle["skippedFiles"], 2);
    assert_eq!(phases["writeTransactions"], 0);
}

#[test]
fn gemini_shared_snapshot_key_in_two_files_requires_replay() {
    let mut oracle = Oracle::new();
    gemini_snapshot(&oracle, "a.json", "shared", 0);
    gemini_snapshot(&oracle, "b.json", "shared", 1);
    oracle.compare_round("Gemini shared snapshot cold");
    let (replay, phases) = oracle.compare_profiled_round("Gemini shared snapshot idle");
    assert_eq!(replay["updated"], 2);
    assert_eq!(phases["writeTransactions"], 2);
    assert_eq!(
        select(&oracle.ledger(0), "SELECT revision FROM usage_records"),
        [json!({"revision":4})]
    );
    gemini_snapshot(&oracle, "b.json", "separate", 1);
    oracle.compare_round("Gemini snapshot keys diverge");
    let (idle, phases) = oracle.compare_profiled_round("Gemini diverged snapshot keys idle");
    assert_eq!(idle["skippedFiles"], 2);
    assert_eq!(phases["writeTransactions"], 0);
}

#[test]
fn declaration_before_target_replays_then_skips_on_the_third_round() {
    let mut oracle = Oracle::new();
    replacement(&oracle, true);
    assert_eq!(
        oracle.compare_round("declaration before target")["counts"]["replaced"],
        0
    );
    assert_replacement(&oracle, true);
    let independent = Source::Codex.path(&oracle.home, 2, false);
    let mut unrelated = codex_usage(2, json!({"response_id":"resp_oracle_independent"}), 22);
    unrelated["payload"]["session_id"] = json!("independent-session");
    oracle.write(&independent, jsonl([unrelated]));
    let replay = oracle.compare_round("pending declaration replay");
    assert_eq!(replay["cachedFiles"], 2);
    assert_eq!(replay["counts"]["replaced"], 1);
    assert_replacement(&oracle, false);
    let (settled, phases) = oracle.compare_profiled_round("settled declaration skips the source");
    assert_eq!(settled["cachedFiles"], 0);
    assert_eq!(settled["skippedFiles"], 3);
    assert_eq!(settled["attempted"], 0);
    assert_eq!(phases["writeSkippedFiles"], 0);
    assert_eq!(phases["writeTransactions"], 0);
    assert_replacement(&oracle, false);
}

#[test]
fn manual_price_changes_with_a_cached_file_in_a_processed_source() {
    let mut oracle = Oracle::new();
    let [first, second] = [0, 1].map(|index| Source::Codex.path(&oracle.home, index, false));
    let unknown_model = "oracle-priced-by-hand";
    let mut usage = codex_usage(0, json!({"response_id":TARGET}), 100);
    usage["payload"]["usage"]["model"] = json!(unknown_model);
    oracle.write(&first, jsonl([usage]));
    oracle.compare_round("usage before manual price");
    let sql = "SELECT revision,cost_micros,price_source FROM usage_records WHERE model='oracle-priced-by-hand'";
    assert_eq!(
        select(&oracle.ledger(0), sql)[0]["cost_micros"],
        Value::Null
    );
    for side in 0..oracle.data.len() {
        crate::stats::pricing::store::save_manual(
            &oracle.data[side],
            &oracle.ledger(side),
            &json!({"model":unknown_model,"currency":"USD","input":10,"output":0}).to_string(),
        )
        .unwrap();
    }
    oracle.write(
        &second,
        jsonl([codex_usage(
            1,
            json!({"response_id":"resp_oracle_new_price_round"}),
            20,
        )]),
    );
    let (result, phases) = oracle.compare_profiled_round("apply manual price");
    assert_eq!(result["repriced"], 1);
    assert_eq!(phases["writeSkippedFiles"], 1);
    assert_eq!(
        select(&oracle.ledger(0), sql),
        [json!({"revision":1,"cost_micros":990,"price_source":"manual:oracle-priced-by-hand"})]
    );
}

#[test]
fn timing_revision_only_replays_without_changing_usage() {
    let mut oracle = Oracle::new();
    let path = Source::Codex.path(&oracle.home, 0, false);
    oracle.write(
        &path,
        encode(
            Source::Codex,
            &[Event {
                id: 1,
                minute: 0,
                tokens: 20,
            }],
        ),
    );
    oracle.compare_round("before timing upgrade");
    let sql = "SELECT * FROM usage_records";
    let usage = select(&oracle.ledger(0), sql);
    let timing_rev = adapters::timing_rev("codex").unwrap() + 1;
    oracle.revisions = Some(Revisions {
        usage: Some(adapters::parser_rev("codex")),
        timing: Some(timing_rev),
    });
    let (result, phases) = oracle.compare_profiled_round("after timing upgrade");
    assert_eq!(result["parsedFiles"], 1);
    assert_eq!(phases["writeTransactions"], 1);
    assert_eq!(phases["writeSkippedFiles"], 0);
    assert_eq!(select(&oracle.ledger(0), sql), usage);
    assert_eq!(
        select(&oracle.ledger(0), "SELECT parser_rev FROM usage_timings"),
        [json!({"parser_rev":timing_rev})]
    );
}

#[test]
fn cached_output_replays_to_fix_its_timing_and_report_omissions() {
    let mut oracle = Oracle::new();
    let [stale, truncated, changed] =
        [0, 1, 2].map(|index| Source::Codex.path(&oracle.home, index, false));
    let event = |id| Event {
        id,
        minute: id as i64,
        tokens: 20,
    };
    oracle.write(&stale, encode(Source::Codex, &[event(1)]));
    oracle.write(&truncated, encode(Source::Codex, &[event(2), event(3)]));
    oracle.compare_round("complete files");
    oracle.write(&truncated, encode(Source::Codex, &[event(2)]));
    oracle.compare_round("one same-revision usage vanished");

    for side in 0..oracle.data.len() {
        oracle
            .ledger(side)
            .db
            .execute(
                "UPDATE usage_timings SET parser_rev=0, generation_ms=5
             WHERE record_key LIKE '%resp_oracle_event_00000001'",
                [],
            )
            .unwrap();
    }
    oracle.write(&changed, encode(Source::Codex, &[event(4)]));
    let (result, phases) = oracle.compare_profiled_round("stale timing and persistent omission");
    assert_eq!(result["cachedFiles"], 2);
    assert_eq!(result["counts"]["vanished"], 1);
    assert_eq!(phases["writeSkippedFiles"], 0);
    assert_eq!(phases["writeTransactions"], 3);
    assert_eq!(
        select(&oracle.ledger(0),
            "SELECT parser_rev,generation_ms FROM usage_timings WHERE record_key LIKE '%resp_oracle_event_00000001'"),
        [json!({"parser_rev":adapters::timing_rev("codex"),"generation_ms":600})],
    );
}

#[test]
fn earlier_new_declaration_can_supersede_a_cached_target() {
    let mut oracle = Oracle::new();
    let [first, second, third] =
        [0, 1, 2].map(|index| Source::Codex.path(&oracle.home, index, false));
    oracle.write(
        &second,
        jsonl([codex_usage(0, json!({"response_id":TARGET}), 20)]),
    );
    oracle.write(
        &third,
        jsonl([codex_usage(
            2,
            json!({"response_id":"resp_oracle_unaffected"}),
            22,
        )]),
    );
    oracle.compare_round("current target and unaffected file");
    oracle.write(
        &first,
        jsonl([codex_usage(1, json!({"turn_id":TARGET}), 40)]),
    );
    let (result, phases) = oracle.compare_profiled_round("earlier batch supersedes a cached row");
    assert_eq!(result["counts"]["replaced"], 1);
    assert_eq!(result["unchanged"], 1);
    assert_eq!(phases["writeSkippedFiles"], 1);
    assert_eq!(phases["writeTransactions"], 2);
}

#[test]
fn target_before_declaration_is_replaced_in_the_first_round() {
    let mut oracle = Oracle::new();
    replacement(&oracle, false);
    assert_eq!(
        oracle.compare_round("target before declaration")["counts"]["replaced"],
        1
    );
    assert_replacement(&oracle, false);
    let settled = oracle.compare_round("no pending replacement");
    assert_eq!(settled["cachedFiles"], 0);
    assert_eq!(settled["skippedFiles"], 2);
    assert_eq!(settled["attempted"], 0);
}

#[test]
fn codex_changes_format_in_both_directions() {
    let mut oracle = Oracle::new();
    let plain = Source::Codex.path(&oracle.home, 0, false);
    let compressed = Source::Codex.path(&oracle.home, 0, true);
    let bytes = encode(
        Source::Codex,
        &[Event {
            id: 1,
            minute: 0,
            tokens: 20,
        }],
    );
    oracle.write(&plain, &bytes);
    oracle.compare_round("plain");
    assert_eq!(owner(&oracle, 1), json!(plain));
    fs::remove_file(&plain).unwrap();
    oracle.write(&compressed, raw_zstd(&bytes));
    oracle.compare_round("JSONL to Zstandard");
    assert_eq!(owner(&oracle, 1), json!(compressed));
    fs::remove_file(&compressed).unwrap();
    oracle.write(&plain, bytes);
    assert_eq!(oracle.compare_round("Zstandard to JSONL")["inserted"], 0);
    assert_eq!(owner(&oracle, 1), json!(plain));
}

#[test]
fn reused_long_id_should_match_full_replay() {
    let mut oracle = Oracle::new();
    let path = Source::Codex.path(&oracle.home, 0, false);
    oracle.write(
        &path,
        jsonl([
            codex_usage(0, json!({"response_id": TARGET}), 100),
            codex_usage(0, json!({"response_id": TARGET}), 200),
        ]),
    );
    oracle.write(
        &Source::Claude.path(&oracle.home, 0, false),
        encode(
            Source::Claude,
            &[Event {
                id: 0,
                minute: 0,
                tokens: 20,
            }],
        ),
    );
    oracle.compare_round("duplicate long ID initial");
    let codex_revision = "SELECT revision FROM usage_records WHERE source='codex'";
    assert_eq!(
        select(&oracle.ledger(0), codex_revision),
        [json!({"revision":2})]
    );
    // A v7 cache written by an older version has no replay metadata.
    let old_fingerprint = fingerprint::fingerprint(
        "codex",
        &path,
        Some("fixed:0"),
        Revisions {
            usage: Some(adapters::parser_rev("codex")),
            timing: adapters::timing_rev("codex"),
        },
    )
    .unwrap();
    oracle
        .ledger(0)
        .db
        .execute(
            "UPDATE ingest_files SET fingerprint=? WHERE source='codex'",
            [old_fingerprint],
        )
        .unwrap();
    for label in ["legacy cache replay", "classified cache replay"] {
        let result = oracle.compare_round(label);
        assert_eq!(result["cachedFiles"], 1);
        assert_eq!(result["skippedFiles"], 1);
        assert_eq!(result["updated"], 2);
    }
    assert_eq!(
        select(&oracle.ledger(0), codex_revision),
        [json!({"revision":6})]
    );
}
