use super::{lines::note, project, sqlite};
use crate::stats::{discovery, Error, Result};
use chrono::{DateTime, SecondsFormat};
use rusqlite::{types::ValueRef, Connection, OptionalExtension, Params, Statement};
use serde_json::{json, Value};
use std::path::Path;

struct BadProto;
type WireResult<T> = std::result::Result<T, BadProto>;

enum WireValue<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Skipped,
}

impl<'a> WireValue<'a> {
    fn number(self) -> WireResult<u64> {
        match self {
            Self::Varint(n) => Ok(n),
            _ => Err(BadProto),
        }
    }

    fn bytes(self) -> WireResult<&'a [u8]> {
        match self {
            Self::Bytes(bytes) => Ok(bytes),
            _ => Err(BadProto),
        }
    }

    fn text(self) -> WireResult<&'a str> {
        std::str::from_utf8(self.bytes()?).map_err(|_| BadProto)
    }
}

struct Fields<'a>(&'a [u8]);

impl<'a> Fields<'a> {
    fn take(&mut self, count: usize) -> WireResult<&'a [u8]> {
        let (bytes, rest) = self.0.split_at_checked(count).ok_or(BadProto)?;
        self.0 = rest;
        Ok(bytes)
    }

    fn varint(&mut self) -> WireResult<u64> {
        let mut value = 0;
        for shift in (0..64).step_by(7) {
            let byte = self.take(1)?[0];
            if shift == 63 && byte > 1 {
                return Err(BadProto);
            }
            value |= u64::from(byte & 0x7f) << shift;
            if byte < 0x80 {
                return Ok(value);
            }
        }
        Err(BadProto)
    }

    fn tag(&mut self) -> WireResult<(u32, u32)> {
        let tag = u32::try_from(self.varint()?).map_err(|_| BadProto)?;
        let field = tag >> 3;
        if field == 0 {
            return Err(BadProto);
        }
        Ok((field, tag & 7))
    }

    fn value(&mut self, field: u32, wire: u32, depth: u8) -> WireResult<WireValue<'a>> {
        match wire {
            0 => return self.varint().map(WireValue::Varint),
            1 => {
                self.take(8)?;
            }
            2 => {
                let len = usize::try_from(self.varint()?).map_err(|_| BadProto)?;
                return self.take(len).map(WireValue::Bytes);
            }
            3 if depth < 64 => loop {
                let (nested, wire) = self.tag()?;
                if wire == 4 {
                    if nested != field {
                        return Err(BadProto);
                    }
                    break;
                }
                self.value(nested, wire, depth + 1)?;
            },
            5 => {
                self.take(4)?;
            }
            _ => return Err(BadProto),
        }
        Ok(WireValue::Skipped)
    }

    fn next(&mut self) -> WireResult<Option<(u32, WireValue<'a>)>> {
        if self.0.is_empty() {
            return Ok(None);
        }
        let (field, wire) = self.tag()?;
        Ok(Some((field, self.value(field, wire, 0)?)))
    }
}

#[derive(Default)]
struct Usage {
    input: u64,
    output: u64,
    cache_read: u64,
}

impl Usage {
    fn read(&mut self, mut fields: Fields<'_>) -> WireResult<()> {
        while let Some((field, value)) = fields.next()? {
            let count = match field {
                2 => &mut self.input,
                3 => &mut self.output,
                5 => &mut self.cache_read,
                _ => continue,
            };
            // Match the ledger's safe integer range and leave room for summing the fields.
            *count = value.number()?;
            if *count > 9_007_199_254_740_991 {
                return Err(BadProto);
            }
        }
        Ok(())
    }
}

#[derive(Default)]
struct Generation<'a> {
    usage: Option<Usage>,
    model: Option<&'a str>,
    request_id: Option<&'a str>,
    last_step: Option<i64>,
}

impl<'a> Generation<'a> {
    fn read(mut fields: Fields<'a>) -> WireResult<Self> {
        let mut generation = Self::default();
        while let Some((field, value)) = fields.next()? {
            if field != 1 {
                continue;
            }
            let mut metadata = Fields(value.bytes()?);
            while let Some((field, value)) = metadata.next()? {
                match field {
                    4 => generation
                        .usage
                        .get_or_insert_with(Usage::default)
                        .read(Fields(value.bytes()?))?,
                    19 => generation.model = Some(value.text()?).filter(|s| !s.is_empty()),
                    20 => generation.attribute(Fields(value.bytes()?))?,
                    _ => {}
                }
            }
        }
        Ok(generation)
    }

    fn attribute(&mut self, mut fields: Fields<'a>) -> WireResult<()> {
        let mut key = "";
        let mut value = &[][..];
        while let Some((field, wire)) = fields.next()? {
            match field {
                1 => key = wire.text()?,
                2 => value = wire.bytes()?,
                _ => {}
            }
        }
        match key {
            "request_id" => {
                self.request_id = Some(std::str::from_utf8(value).map_err(|_| BadProto)?)
                    .filter(|s| !s.is_empty());
            }
            "last_step_index" => {
                self.last_step = std::str::from_utf8(value)
                    .map_err(|_| BadProto)?
                    .parse()
                    .ok();
            }
            _ => {}
        }
        Ok(())
    }
}

fn seconds(blob: &[u8], timestamp_field: u32) -> WireResult<Option<i64>> {
    let mut seconds = None;
    let mut metadata = Fields(blob);
    while let Some((field, value)) = metadata.next()? {
        if field != timestamp_field {
            continue;
        }
        let mut timestamp = Fields(value.bytes()?);
        while let Some((field, value)) = timestamp.next()? {
            if field == 1 {
                // Protobuf int64 uses a two's complement varint for negative seconds.
                seconds = Some(value.number()? as i64);
            }
        }
    }
    Ok(seconds)
}

enum Time {
    Missing,
    BadBlob,
    Observed(String),
}

fn read_time(query: &mut Option<Statement<'_>>, params: impl Params, tag: u32) -> Result<Time> {
    let Some(query) = query else {
        return Ok(Time::Missing);
    };
    Ok(query
        .query_row(params, |row| {
            Ok(match row.get_ref(0)? {
                ValueRef::Null => Time::Missing,
                ValueRef::Blob(blob) => match seconds(blob, tag) {
                    Ok(seconds) => seconds
                        .and_then(|s| DateTime::from_timestamp(s, 0))
                        .map_or(Time::Missing, |t| {
                            Time::Observed(t.to_rfc3339_opts(SecondsFormat::Millis, true))
                        }),
                    Err(_) => Time::BadBlob,
                },
                _ => Time::BadBlob,
            })
        })
        .optional()?
        .unwrap_or(Time::Missing))
}

struct Times<'a> {
    reply: Option<Statement<'a>>,
    next_step: Option<Statement<'a>>,
    trajectory: Option<Statement<'a>>,
}

impl<'a> Times<'a> {
    fn prepare(db: &'a Connection, notes: &mut Value) -> Result<Self> {
        let has_steps = sqlite::table_exists(db, "steps", notes)?;
        let has_trajectory = sqlite::table_exists(db, "trajectory_metadata_blob", notes)?;
        Ok(Self {
            reply: has_steps
                .then(|| {
                    db.prepare(
                "SELECT metadata FROM steps WHERE idx > ?1 AND step_type = 15 ORDER BY idx LIMIT 1",
            )
                })
                .transpose()?,
            next_step: has_steps
                .then(|| db.prepare("SELECT metadata FROM steps WHERE idx = ?1"))
                .transpose()?,
            trajectory: has_trajectory
                .then(|| {
                    db.prepare("SELECT data FROM trajectory_metadata_blob ORDER BY id LIMIT 1")
                })
                .transpose()?,
        })
    }

    fn observed_at(&mut self, last_step: Option<i64>) -> Result<Time> {
        if let Some(idx) = last_step {
            let reply = read_time(&mut self.reply, [idx], 1)?;
            if !matches!(reply, Time::Missing) {
                return Ok(reply);
            }
            if let Some(idx) = idx.checked_add(1) {
                let next = read_time(&mut self.next_step, [idx], 1)?;
                if !matches!(next, Time::Missing) {
                    return Ok(next);
                }
            }
        }
        read_time(&mut self.trajectory, [], 2)
    }
}

fn workspace(path: &Path, session_id: &str, preview_home: Option<&Path>) -> Result<Option<String>> {
    if preview_home.is_some_and(|home| !discovery::preview_allows_sqlite(home, path))
        || !path.try_exists()?
    {
        return Ok(None);
    }
    let db = sqlite::open(path)?;
    let value = db
        .query_row(
            "SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ?1",
            [session_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    let uris: Value = match value {
        Some(value) => serde_json::from_str(&value)?,
        None => return Ok(None),
    };
    let uri = uris
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .find(|uri| uri.starts_with("file://"));
    let path = uri
        .and_then(|uri| reqwest::Url::parse(uri).ok())
        .and_then(|url| url.to_file_path().ok());
    Ok(path
        .as_deref()
        .and_then(Path::to_str)
        .and_then(|path| project::project(&json!(path))))
}

pub(super) fn parse(
    file: &Path,
    preview_home: Option<&Path>,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    if preview_home.is_some_and(|home| !discovery::preview_allows_sqlite(home, file)) {
        return Err(Error("SQLite 会话库或其日志文件不在预览沙箱内".into()));
    }
    let session_id = file
        .file_stem()
        .and_then(|name| name.to_str())
        .ok_or_else(|| Error("Antigravity 会话文件名不是有效的 UTF-8".into()))?;
    let project = file.parent().and_then(Path::parent).and_then(|dir| {
        match workspace(
            &dir.join("conversation_summaries.db"),
            session_id,
            preview_home,
        ) {
            Ok(project) => project,
            Err(_) => {
                note(notes, "bad_fields");
                None
            }
        }
    });
    let mut db = sqlite::open(file)?;
    // A single read snapshot keeps generation rows and their steps consistent during appends.
    let snapshot = db.transaction()?;
    let mut times = Times::prepare(&snapshot, notes)?;
    let mut statement = snapshot.prepare("SELECT idx, data FROM gen_metadata ORDER BY idx")?;
    let mut rows = statement.query([])?;
    let mut records = Vec::new();
    while let Some(row) = rows.next()? {
        let idx: i64 = row.get(0)?;
        let generation = match row.get_ref(1)? {
            ValueRef::Blob(blob) => Generation::read(Fields(blob)),
            _ => Err(BadProto),
        };
        let Ok(generation) = generation else {
            note(notes, "bad_lines");
            continue;
        };
        let Some(usage) = generation.usage else {
            continue;
        };
        if usage.input == 0 && usage.output == 0 && usage.cache_read == 0 {
            note(notes, "zero_usage");
            continue;
        }
        let time = match times.observed_at(generation.last_step)? {
            Time::Observed(time) => time,
            Time::Missing => {
                note(notes, "bad_times");
                note(notes, "rejected_missing_time");
                continue;
            }
            Time::BadBlob => {
                note(notes, "bad_lines");
                continue;
            }
        };
        let key = match generation.request_id {
            Some(id) => format!("antigravity:{id}"),
            None => format!("antigravity:{session_id}:{idx}"),
        };
        records.push(json!({
            "record_key": key, "source": "antigravity", "kind": "event",
            "session_id": session_id, "project_key": project, "model": generation.model,
            "provider": null, "observed_at": time, "input_tokens": usage.input,
            "output_tokens": usage.output, "cache_read_tokens": usage.cache_read, "cache_write_tokens": null
        }));
    }
    Ok(records)
}
