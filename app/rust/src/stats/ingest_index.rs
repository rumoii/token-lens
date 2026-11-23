use super::{replacement_targets, FileOutput, Input, Ledger, Result, Revisions};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::Arc,
};

pub(super) const MEMORY_LIMIT: usize = 256 * 1024 * 1024;
type Name = Arc<str>;

#[derive(Default)]
struct Links {
    forward: HashMap<Name, HashSet<Name>>,
    reverse: HashMap<Name, HashSet<Name>>,
    bytes: usize,
}

impl Links {
    fn add(&mut self, file: &Name, key: &Name) {
        if self
            .forward
            .entry(file.clone())
            .or_default()
            .insert(key.clone())
        {
            self.reverse
                .entry(key.clone())
                .or_default()
                .insert(file.clone());
            self.bytes += 224 + file.len() + key.len();
        }
    }

    fn remove(&mut self, file: &Name, key: &Name) {
        let keys = self.forward.get_mut(file).expect("known file");
        keys.remove(key);
        if keys.is_empty() {
            self.forward.remove(file);
        }
        let files = self.reverse.get_mut(key).expect("known key");
        files.remove(file);
        if files.is_empty() {
            self.reverse.remove(key);
        }
        self.bytes -= 224 + file.len() + key.len();
    }
}

pub(super) struct Summary {
    // Preserve raw order and repeated keys before settlement removes copies.
    records: Vec<(Name, bool)>,
    replaces: Vec<Name>,
    earliest: Option<String>,
    pub(super) notes: HashMap<String, i64>,
    pub(super) attempted: usize,
    pub(super) copies: usize,
    pub(super) replay: bool,
    pub(super) order: usize,
}

impl Summary {
    pub(super) fn new(output: &FileOutput) -> Self {
        Self {
            records: output
                .records
                .iter()
                .filter_map(|record| {
                    let key = record["record_key"].as_str()?;
                    Some((key.into(), record["kind"] == "event"))
                })
                .collect(),
            replaces: output
                .records
                .iter()
                .flat_map(replacement_targets)
                .map(Name::from)
                .collect(),
            earliest: output
                .records
                .iter()
                .filter_map(|record| record["observed_at"].as_str())
                .min()
                .map(str::to_owned),
            notes: output.notes.clone(),
            attempted: 0,
            copies: 0,
            replay: true,
            order: 0,
        }
    }

    fn links(&self) -> impl Iterator<Item = &Name> {
        self.records
            .iter()
            .map(|(key, _)| key)
            .chain(&self.replaces)
    }

    pub(super) fn bytes(&self, file: &str) -> usize {
        416 + file.len() * 2
            + self.earliest.as_ref().map_or(0, String::capacity)
            + self
                .notes
                .keys()
                .map(|name| 72 + name.capacity())
                .sum::<usize>()
            + self
                .records
                .iter()
                .map(|(key, event)| std::mem::size_of_val(event) + 64 + key.len())
                .sum::<usize>()
            + self
                .replaces
                .iter()
                .map(|key| 64 + key.len())
                .sum::<usize>()
    }
}

#[derive(Default)]
pub(super) struct SourceIndex {
    pub(super) files: HashMap<Name, Summary>,
    replay: HashSet<Name>,
    raw: Links,
    // The union of the actual usage and timing owners, including inactive usage.
    owners: Links,
    bytes: usize,
    pub(super) timing_current: bool,
}

pub(super) struct Affected {
    pub(super) files: HashSet<Name>,
    keys: HashSet<Name>,
}

impl SourceIndex {
    pub(super) fn bytes(&self) -> usize {
        self.bytes + self.raw.bytes + self.owners.bytes
    }

    pub(super) fn owner_paths(&self) -> impl Iterator<Item = &str> {
        self.owners.forward.keys().map(AsRef::as_ref)
    }

    pub(super) fn compatible(&self, inputs: &[Input<'_>], removed: &[String]) -> bool {
        // Relative discovery order is part of settle's stable tie break.
        let mut previous_order = None;
        for input in inputs {
            if let Some(file) = self.files.get(input.file.as_str()) {
                if previous_order.is_some_and(|order| order >= file.order) || !input.had_cache {
                    return false;
                }
                if input.hit == Some(super::CacheReplay::Unknown) {
                    return false;
                }
                previous_order = Some(file.order);
            } else if input.had_cache {
                return false;
            }
        }
        removed
            .iter()
            .all(|file| self.files.contains_key(file.as_str()))
    }

    pub(super) fn affected(
        &self,
        changed: &HashMap<String, Option<Summary>>,
        removed: &[String],
        file_count: usize,
    ) -> Option<Affected> {
        let mut new = Links::default();
        for (file, summary) in changed {
            if let Some(summary) = summary {
                let file = Name::from(file.as_str());
                for key in summary.links() {
                    new.add(&file, key);
                }
            }
        }
        let mut queue: VecDeque<Name> = self
            .replay
            .iter()
            .cloned()
            .chain(
                changed
                    .keys()
                    .chain(removed)
                    .map(|file| Name::from(file.as_str())),
            )
            .collect();
        let mut files = HashSet::new();
        let mut keys = HashSet::new();
        while let Some(file) = queue.pop_front() {
            if files.contains(&file) {
                continue;
            }
            for key in [&self.raw, &self.owners, &new]
                .into_iter()
                .flat_map(|links| links.forward.get(&file).into_iter().flatten())
            {
                if keys.insert(key.clone()) {
                    for peer in [&self.raw, &self.owners, &new]
                        .into_iter()
                        .flat_map(|links| links.reverse.get(key).into_iter().flatten())
                    {
                        queue.push_back(peer.clone());
                    }
                }
            }
            files.insert(file);
            if files.len() > file_count / 2 || keys.len() > 32_768 {
                return None;
            }
        }
        Some(Affected { files, keys })
    }

    pub(super) fn remove(&mut self, file: &str) {
        if let Some((file, old)) = self.files.remove_entry(file) {
            self.bytes -= old.bytes(&file);
            self.replay.remove(&file);
            for key in old.links().collect::<HashSet<_>>() {
                self.raw.remove(&file, key);
            }
        }
    }

    pub(super) fn put(&mut self, file: &str, summary: Summary) {
        self.remove(file);
        let file = Name::from(file);
        for key in summary.links() {
            self.raw.add(&file, key);
        }
        self.bytes += summary.bytes(&file);
        if summary.replay {
            self.replay.insert(file.clone());
        }
        self.files.insert(file, summary);
    }

    pub(super) fn refresh_owners(
        &mut self,
        ledger: &Ledger,
        source: &str,
        revisions: Revisions,
        affected: Option<&Affected>,
        cancelled: impl Fn() -> bool,
    ) -> Result<bool> {
        let sql = if let Some(affected) = affected {
            // The closure includes all previous file-owned keys as well as new keys.
            for key in &affected.keys {
                if let Some(files) = self.owners.reverse.get(key).cloned() {
                    for file in &files {
                        self.owners.remove(file, key);
                    }
                }
            }
            "SELECT u.record_key,u.source_file,NULL,0 FROM json_each(?1) k
             CROSS JOIN usage_records u ON u.record_key=k.value WHERE u.source_file IS NOT NULL
             UNION ALL
             SELECT t.record_key,t.source_file,coalesce(t.parser_rev,1),1 FROM json_each(?1) k
             CROSS JOIN usage_timings t ON t.record_key=k.value WHERE t.source_file IS NOT NULL"
        } else {
            self.owners = Links::default();
            self.timing_current = true;
            "SELECT record_key,source_file,NULL,0 FROM usage_records WHERE source=?1 AND source_file IS NOT NULL
             UNION ALL
             SELECT record_key,source_file,coalesce(parser_rev,1),1 FROM usage_timings WHERE source=?1 AND source_file IS NOT NULL"
        };
        let keys;
        let argument = if let Some(affected) = affected {
            keys = serde_json::to_string(
                &affected
                    .keys
                    .iter()
                    .map(AsRef::as_ref)
                    .collect::<Vec<&str>>(),
            )?;
            &keys
        } else {
            source
        };
        let mut stmt = ledger.db.prepare_cached(sql)?;
        let mut rows = stmt.query([argument])?;
        while let Some(row) = rows.next()? {
            if cancelled() {
                return Err(super::Error("cancelled".into()));
            }
            let (Ok(key), Ok(file)) = (row.get_ref(0)?.as_str(), row.get_ref(1)?.as_str()) else {
                return Ok(false);
            };
            let (file, key) = (Name::from(file), Name::from(key));
            self.owners.add(&file, &key);
            if row.get::<_, bool>(3)? && revisions.timing.is_some() {
                self.timing_current &=
                    row.get::<_, Option<i64>>(2).ok().flatten() == revisions.timing;
            }
            if self.bytes() > MEMORY_LIMIT {
                return Ok(false);
            }
        }
        Ok(true)
    }
}
