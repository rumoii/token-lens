use super::{
    payload_hash, replacement_targets, timing_hash, timing_values, validate, Error, HashMap,
    HashSet, Ledger, Result, Revisions, Value, ValueRef, TIMING_FIELDS,
};
use rusqlite::{params, Row};
use serde_json::json;

pub(in crate::stats) struct WriteCandidate<'a> {
    pub file: &'a str,
    pub records: &'a [Value],
    pub elsewhere: &'a [String],
    pub cache_unchanged: bool,
}

#[derive(Default)]
pub(in crate::stats) struct WriteSkips {
    data_version: i64,
    files: HashSet<usize>,
}

impl WriteSkips {
    pub(in crate::stats) fn contains(&self, index: usize, ledger: &Ledger) -> Result<bool> {
        Ok(self.files.contains(&index) && ledger.data_version()? == self.data_version)
    }
}

struct FileProof<'a> {
    index: usize,
    elsewhere: &'a [String],
    records: HashMap<&'a str, &'a Value>,
    matched: usize,
    unchanged: bool,
}

impl Ledger {
    pub(in crate::stats) fn write_skips(
        &self,
        files: &[WriteCandidate<'_>],
        revisions: Revisions,
        cancelled: impl Fn() -> bool,
    ) -> Result<WriteSkips> {
        if !files.iter().any(|input| input.cache_unchanged) {
            return Ok(WriteSkips::default());
        }
        let mut isolated = vec![true; files.len()];
        let mut paths = HashMap::new();
        let mut keys = HashMap::new();
        for (index, input) in files.iter().enumerate() {
            check_cancelled(&cancelled)?;
            if let Some(other) = paths.insert(input.file, index) {
                isolated[index] = false;
                isolated[other] = false;
            }
            for key in input
                .records
                .iter()
                .filter_map(|r| r["record_key"].as_str())
            {
                if let Some(other) = keys.insert(key, index).filter(|other| *other != index) {
                    isolated[index] = false;
                    isolated[other] = false;
                }
            }
        }
        for (index, input) in files.iter().enumerate() {
            check_cancelled(&cancelled)?;
            // A batch may activate a later batch's target, or supersede a key
            // read by another batch. Two declarations alone can only deactivate it.
            for target in input.records.iter().flat_map(replacement_targets) {
                if let Some(other) = keys.get(target).copied().filter(|other| *other != index) {
                    isolated[index] = false;
                    isolated[other] = false;
                }
            }
        }
        drop(keys);
        let mut proofs = HashMap::new();
        for (index, input) in files.iter().enumerate() {
            if !isolated[index] || !input.cache_unchanged {
                continue;
            }
            let mut records = HashMap::with_capacity(input.records.len());
            let eligible = input.records.iter().all(|record| {
                matches!(record["kind"].as_str(), Some("event" | "cumulative"))
                    && validate(record).is_none()
                    && records
                        .insert(record["record_key"].as_str().unwrap(), record)
                        .is_none()
            });
            if eligible {
                proofs.insert(
                    input.file,
                    FileProof {
                        index,
                        elsewhere: input.elsewhere,
                        records,
                        matched: 0,
                        unchanged: true,
                    },
                );
            }
        }
        if proofs.is_empty() {
            return Ok(WriteSkips::default());
        }

        // A successful proof needs this file's usage and existing timing to
        // already belong to it. Other batches can neither assign rows to this
        // file nor reach its checked keys. File-level cleanup can only remove
        // rows, so an already covered omission set stays covered.
        let data_version = self.data_version()?;
        let targets: HashSet<_> = proofs
            .values()
            .flat_map(|proof| proof.records.values())
            .flat_map(|record| replacement_targets(record))
            .collect();
        if !targets.is_empty() {
            // Drive the join from the target list so each lookup uses the
            // unique record_key index instead of rescanning the JSON per active row.
            let mut statement = self.db.prepare_cached(
                "SELECT u.record_key FROM json_each(?) AS target
                 CROSS JOIN usage_records u ON u.record_key=target.value
                 WHERE u.active=1",
            )?;
            let mut rows = statement.query([serde_json::to_string(&targets)?])?;
            let mut active = HashSet::new();
            while let Some(row) = rows.next()? {
                check_cancelled(&cancelled)?;
                active.insert(row.get::<_, String>(0)?);
            }
            if !active.is_empty() {
                proofs.retain(|_, proof| {
                    !proof
                        .records
                        .values()
                        .flat_map(|record| replacement_targets(record))
                        .any(|target| active.contains(target))
                });
                if proofs.is_empty() {
                    return Ok(WriteSkips::default());
                }
            }
        }
        let paths = serde_json::to_string(&proofs.keys().collect::<Vec<_>>())?;
        let timing_fields = TIMING_FIELDS.map(|field| format!("t.{field}")).join(",");
        let sql = format!(
            "SELECT u.source_file,u.record_key,u.content_hash,u.parser_rev,u.project_key,
                    u.ended_at IS NULL,u.superseded_by IS NULL,
                    t.record_key,t.source_file,t.parser_rev,t.source,t.timing_hash,{timing_fields}
             FROM usage_records u LEFT JOIN usage_timings t USING(record_key)
             WHERE u.source_file IN (SELECT value FROM json_each(?)) AND u.active=1"
        );
        let mut statement = self.db.prepare_cached(&sql)?;
        let mut rows = statement.query([paths])?;
        while let Some(row) = rows.next()? {
            check_cancelled(&cancelled)?;
            let Some((file, proof)) = row
                .get_ref(0)?
                .as_str()
                .ok()
                .and_then(|file| proofs.get_mut(file).map(|proof| (file, proof)))
            else {
                continue;
            };
            if !proof.unchanged {
                continue;
            }
            let key = row.get_ref(1)?.as_str().ok();
            if let Some(record) = key.and_then(|key| proof.records.get(key)) {
                proof.unchanged = usage_unchanged(row, record, revisions.usage)?
                    && timing_unchanged(row, record, file, revisions.timing)?;
                proof.matched += 1;
            } else if !proof.records.is_empty() || !proof.elsewhere.is_empty() {
                // Even a same-revision omission would report a vanished record.
                proof.unchanged =
                    key.is_some_and(|key| proof.elsewhere.iter().any(|other| other == key));
            }
        }
        drop(rows);
        if let Some(revision) = revisions.timing {
            let mut statement = self.db.prepare_cached(
                "SELECT source_file,record_key FROM usage_timings
                 WHERE coalesce(parser_rev,1)!=?",
            )?;
            let mut rows = statement.query(params![revision])?;
            while let Some(row) = rows.next()? {
                check_cancelled(&cancelled)?;
                if let Some(proof) = row
                    .get_ref(0)?
                    .as_str()
                    .ok()
                    .and_then(|file| proofs.get_mut(file))
                {
                    let key = row.get_ref(1)?.as_str().ok();
                    proof.unchanged &=
                        key.is_some_and(|key| proof.elsewhere.iter().any(|other| other == key));
                }
            }
        }
        Ok(WriteSkips {
            data_version,
            files: proofs
                .into_values()
                .filter(|proof| proof.unchanged && proof.matched == proof.records.len())
                .map(|proof| proof.index)
                .collect(),
        })
    }
}

fn check_cancelled(cancelled: impl Fn() -> bool) -> Result<()> {
    if cancelled() {
        return Err(Error("cancelled".into()));
    }
    Ok(())
}

fn usage_unchanged(row: &Row<'_>, record: &Value, revision: Option<i64>) -> Result<bool> {
    // Validate the hash of the effective usage. When ended_at would fall back
    // to a stored value, leave the batch to the writer.
    let old_revision = row.get_ref(3)?;
    if !row.get::<_, bool>(6)?
        || (record["ended_at"].is_null() && !row.get::<_, bool>(5)?)
        || revision.is_some_and(|revision| old_revision != ValueRef::Integer(revision))
    {
        return Ok(false);
    }
    let project = &record["project_key"];
    if !project.is_null() {
        let old_project = row.get_ref(4)?.as_str().ok();
        if !project
            .as_str()
            .is_some_and(|project| old_project == Some(project))
        {
            return Ok(false);
        }
    }
    // The matching-hash branch has no price assignments. Repricing still runs
    // at the end of sync, independently of the per-file batch.
    Ok(row.get_ref(2)?.as_str().ok() == Some(payload_hash(record).as_str()))
}

fn timing_unchanged(
    row: &Row<'_>,
    record: &Value,
    file: &str,
    revision: Option<i64>,
) -> Result<bool> {
    if row.get_ref(7)? == ValueRef::Null {
        return Ok(timing_values(record, None).is_none());
    }
    let old_revision = row.get_ref(9)?;
    if row.get_ref(8)?.as_str().ok() != Some(file)
        || revision.is_some_and(|revision| old_revision != ValueRef::Integer(revision))
        || row.get_ref(10)?.as_str().ok() != record["source"].as_str()
    {
        return Ok(false);
    }
    let mut old: [Value; TIMING_FIELDS.len()] = Default::default();
    for (index, value) in old.iter_mut().enumerate() {
        *value = match row.get_ref(12 + index)? {
            ValueRef::Null => Value::Null,
            ValueRef::Integer(value) => json!(value),
            ValueRef::Real(value) => json!(value),
            ValueRef::Text(value) => json!(String::from_utf8_lossy(value)),
            ValueRef::Blob(_) => return Ok(false),
        };
    }
    let Some(values) = timing_values(record, Some(std::array::from_fn(|index| &old[index]))) else {
        return Ok(false);
    };
    Ok(values.into_iter().zip(&old).all(|(a, b)| a == b)
        && row.get_ref(11)?.as_str().ok() == Some(timing_hash(&values)?.as_str()))
}
