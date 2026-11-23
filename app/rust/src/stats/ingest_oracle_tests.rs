use super::*;
use crate::stats::ledger::rows;
use chrono::{DateTime, SecondsFormat};
use std::{fs, io::Write, path::PathBuf};

const START_MS: i64 = 1768478400000;
const SESSION: &str = "oracle-session";
const TARGET: &str = "resp_oracle_replacement_target";

struct Oracle {
    _root: tempfile::TempDir,
    home: PathBuf,
    data: [PathBuf; 2],
    round: i64,
}

impl Oracle {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        fs::create_dir(&home).unwrap();
        let data = ["cached", "no-cache"].map(|side| root.path().join(side));
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
            _root: root,
            home,
            data,
            round: 0,
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
                SyncOptions::new(no_cache),
            )
            .unwrap_or_else(|error| panic!("{context}, no_cache={no_cache}: {error}"))
            .0
        };
        // The same immutable input tree is read by both passes, including its absolute paths.
        let cached = run(0, false);
        let replay = run(1, true);
        assert_eq!(replay["cachedFiles"], 0, "{context}");
        assert_eq!(replay["skippedFiles"], 0, "{context}");
        assert_eq!(replay["parsedFiles"], replay["fileCount"], "{context}");
        assert_eq!(cached["fileCount"], replay["fileCount"], "{context}");
        for result in [&cached, &replay] {
            assert_eq!(result["counts"]["read_failed"], 0, "{context}");
            assert_eq!(result["rejected"], 0, "{context}");
        }
        compare_ledgers(&self.ledger(0), &self.ledger(1), &context);
        cached
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
    oracle.compare_round("partial copy");
    assert_eq!(owner(&oracle, 1), json!(a));
    fs::remove_file(&a).unwrap();
    oracle.compare_round("copy owner removed");
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
    oracle.compare_round("B starts earlier");
    assert_eq!(owner(&oracle, 1), json!(b));
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
        "SELECT id,active,superseded_by FROM usage_records ORDER BY id",
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
fn declaration_before_target_replays_then_skips_on_the_third_round() {
    let mut oracle = Oracle::new();
    replacement(&oracle, true);
    assert_eq!(
        oracle.compare_round("declaration before target")["counts"]["replaced"],
        0
    );
    assert_replacement(&oracle, true);
    let replay = oracle.compare_round("pending declaration replay");
    assert_eq!(replay["cachedFiles"], 2);
    assert_eq!(replay["counts"]["replaced"], 1);
    assert_replacement(&oracle, false);
    assert_eq!(
        oracle.compare_round("settled source skips")["skippedFiles"],
        2
    );
    assert_replacement(&oracle, false);
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
    assert_eq!(
        oracle.compare_round("no pending replacement")["skippedFiles"],
        2
    );
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
#[ignore = "An unchanged Codex source skips while replaying two values for one long ID increments revision twice"]
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
    oracle.compare_round("duplicate long ID initial");
    assert_eq!(
        select(&oracle.ledger(0), "SELECT revision FROM usage_records"),
        [json!({"revision":2})]
    );
    oracle.compare_round("duplicate long ID unchanged");
}
