use super::{replacement_targets, FileOutput, Input, Ledger, Result, Revisions};
use std::{
    borrow::Borrow,
    collections::{HashMap, HashSet, VecDeque},
    mem::size_of,
    num::NonZeroU32,
    sync::Arc,
};

pub(super) const MEMORY_LIMIT: usize = 64 * 1024 * 1024;
type Name = Arc<str>;
type FileId = NonZeroU32;

// A boxed string gives each shared key a one-word handle in both directions.
#[derive(Clone, Hash, PartialEq, Eq)]
struct RecordKey(Arc<Box<str>>);

impl RecordKey {
    fn new(text: &str) -> Self {
        Self(Arc::new(text.into()))
    }

    fn bytes(text: &str) -> usize {
        2 * size_of::<usize>() + size_of::<Box<str>>() + text.len()
    }
}

impl AsRef<str> for RecordKey {
    fn as_ref(&self) -> &str {
        self.0.as_ref()
    }
}

impl Borrow<str> for RecordKey {
    fn borrow(&self) -> &str {
        self.as_ref()
    }
}

fn name_bytes(text: &str) -> usize {
    (2 * size_of::<usize>() + text.len()).next_multiple_of(size_of::<usize>())
}

fn table_bytes<T>(capacity: usize) -> usize {
    if capacity == 0 {
        return 0;
    }
    // Allow for empty buckets, control bytes and alignment in the hash table.
    (capacity + 1).next_power_of_two() * (size_of::<T>() + 1) + 64
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Relation {
    Raw,
    Owner,
}

#[derive(Default)]
struct Links {
    raw: Option<FileId>,
    owner: Option<FileId>,
}

impl Links {
    fn first(&mut self, relation: Relation) -> &mut Option<FileId> {
        match relation {
            Relation::Raw => &mut self.raw,
            Relation::Owner => &mut self.owner,
        }
    }
}

#[derive(Default)]
struct Keys {
    links: HashMap<RecordKey, Links>,
    // A second file in either relation is uncommon. Keep the common case inline.
    extra: HashMap<RecordKey, Vec<(Relation, FileId)>>,
    text_bytes: usize,
    extra_bytes: usize,
    link_capacity: usize,
    extra_capacity: usize,
}

impl Keys {
    fn add(
        &mut self,
        text: &str,
        relation: Relation,
        file: FileId,
        new_key: impl FnOnce() -> RecordKey,
    ) -> Option<RecordKey> {
        let name = if let Some((name, _)) = self.links.get_key_value(text) {
            name.clone()
        } else {
            let name = new_key();
            self.text_bytes += RecordKey::bytes(text);
            self.links.insert(name.clone(), Links::default());
            self.link_capacity = self.link_capacity.max(self.links.capacity());
            name
        };
        let first = self.links.get_mut(text).unwrap().first(relation);
        match *first {
            None => *first = Some(file),
            Some(existing) if existing == file => return None,
            Some(_) => {
                let extra = self.extra.entry(name.clone()).or_default();
                let edge = (relation, file);
                if extra.contains(&edge) {
                    return None;
                }
                let before = extra.capacity();
                extra.push(edge);
                self.extra_bytes += (extra.capacity() - before) * size_of::<(Relation, FileId)>();
                self.extra_capacity = self.extra_capacity.max(self.extra.capacity());
            }
        }
        Some(name)
    }

    fn remove(&mut self, text: &str, relation: Relation, file: FileId) {
        let links = self.links.get_mut(text).expect("indexed key");
        let first = links.first(relation);
        if let Some(extra) = self.extra.get_mut(text) {
            let position = if *first == Some(file) {
                extra.iter().position(|&(kind, _)| kind == relation)
            } else {
                Some(
                    extra
                        .iter()
                        .position(|&edge| edge == (relation, file))
                        .unwrap(),
                )
            };
            if let Some(position) = position {
                let (_, replacement) = extra.swap_remove(position);
                if *first == Some(file) {
                    *first = Some(replacement);
                }
            } else {
                *first = None;
            }
            if extra.is_empty() {
                self.extra_bytes -= extra.capacity() * size_of::<(Relation, FileId)>();
                self.extra.remove(text);
            }
        } else {
            debug_assert_eq!(*first, Some(file));
            *first = None;
        }
        if links.raw.is_none() && links.owner.is_none() {
            self.links.remove(text);
            self.text_bytes -= RecordKey::bytes(text);
        }
    }

    fn files<'a>(&'a self, key: &'a str) -> impl Iterator<Item = FileId> + 'a {
        self.links
            .get(key)
            .into_iter()
            .flat_map(|links| links.raw.into_iter().chain(links.owner))
            .chain(
                self.extra
                    .get(key)
                    .into_iter()
                    .flatten()
                    .map(|&(_, file)| file),
            )
    }

    fn bytes(&self) -> usize {
        self.text_bytes
            + self.extra_bytes
            + table_bytes::<(RecordKey, Links)>(self.link_capacity)
            + table_bytes::<(RecordKey, Vec<(Relation, FileId)>)>(self.extra_capacity)
    }
}

pub(super) struct Summary {
    // Only graph membership is needed here. Settlement still reads ordered raw output.
    keys: Vec<RecordKey>,
    pub(super) notes: HashMap<String, i64>,
    pub(super) attempted: usize,
    pub(super) copies: usize,
    pub(super) replay: bool,
    pub(super) order: usize,
}

impl Summary {
    pub(super) fn new(output: &FileOutput) -> Self {
        let mut keys = Vec::with_capacity(output.records.len());
        keys.extend(
            output
                .records
                .iter()
                .filter_map(|record| record["record_key"].as_str())
                .map(RecordKey::new),
        );
        keys.extend(
            output
                .records
                .iter()
                .flat_map(replacement_targets)
                .map(RecordKey::new),
        );
        Self {
            keys,
            notes: output.notes.clone(),
            attempted: 0,
            copies: 0,
            replay: true,
            order: 0,
        }
    }

    fn heap_bytes(&self) -> usize {
        self.keys.capacity() * size_of::<RecordKey>()
            + table_bytes::<(String, i64)>(self.notes.capacity())
            + self.notes.keys().map(String::capacity).sum::<usize>()
    }

    pub(super) fn staging_bytes(&self) -> usize {
        size_of::<Self>()
            + self.heap_bytes()
            + self
                .keys
                .iter()
                .map(|key| RecordKey::bytes(key.as_ref()))
                .sum::<usize>()
    }
}

struct IndexedFile {
    path: Name,
    summary: Option<Summary>,
    owners: Vec<RecordKey>,
}

#[derive(Default)]
pub(super) struct SourceIndex {
    paths: HashMap<Name, FileId>,
    files: Vec<Option<IndexedFile>>,
    free: Vec<FileId>,
    replay: HashSet<FileId>,
    keys: Keys,
    file_bytes: usize,
    path_capacity: usize,
    replay_capacity: usize,
    pub(super) timing_current: bool,
}

pub(super) struct Affected {
    pub(super) files: HashSet<Name>,
    keys: HashSet<RecordKey>,
}

impl SourceIndex {
    pub(super) fn bytes(&self) -> usize {
        self.keys.bytes()
            + self.file_bytes
            + table_bytes::<(Name, FileId)>(self.path_capacity)
            + table_bytes::<FileId>(self.replay_capacity)
            + self.files.capacity() * size_of::<Option<IndexedFile>>()
            + self.free.capacity() * size_of::<FileId>()
    }

    fn file(&self, id: FileId) -> &IndexedFile {
        self.files[id.get() as usize - 1].as_ref().unwrap()
    }

    fn file_mut(&mut self, id: FileId) -> &mut IndexedFile {
        self.files[id.get() as usize - 1].as_mut().unwrap()
    }

    fn file_id(&mut self, path: &str) -> FileId {
        if let Some(&id) = self.paths.get(path) {
            return id;
        }
        let path = Name::from(path);
        let id = self.free.pop().unwrap_or_else(|| {
            self.files.push(None);
            NonZeroU32::new(
                self.files
                    .len()
                    .try_into()
                    .expect("file count within index budget"),
            )
            .unwrap()
        });
        self.file_bytes += name_bytes(&path);
        self.paths.insert(path.clone(), id);
        self.path_capacity = self.path_capacity.max(self.paths.capacity());
        self.files[id.get() as usize - 1] = Some(IndexedFile {
            path,
            summary: None,
            owners: Vec::new(),
        });
        id
    }

    fn prune(&mut self, id: FileId) {
        let entry = self.file(id);
        if entry.summary.is_none() && entry.owners.is_empty() {
            let entry = self.files[id.get() as usize - 1].take().unwrap();
            self.file_bytes -= name_bytes(&entry.path);
            self.paths.remove(entry.path.as_ref());
            self.free.push(id);
        }
    }

    pub(super) fn summary_mut(&mut self, path: &str) -> Option<&mut Summary> {
        let id = *self.paths.get(path)?;
        self.file_mut(id).summary.as_mut()
    }

    pub(super) fn contains_file(&self, path: &str) -> bool {
        self.paths
            .get(path)
            .is_some_and(|&id| self.file(id).summary.is_some())
    }

    pub(super) fn owner_paths(&self) -> impl Iterator<Item = &str> {
        self.files
            .iter()
            .flatten()
            .filter(|file| !file.owners.is_empty())
            .map(|file| file.path.as_ref())
    }

    pub(super) fn compatible(&self, inputs: &[Input<'_>], removed: &[String]) -> bool {
        // Relative discovery order is part of settle's stable tie break.
        let mut previous_order = None;
        for input in inputs {
            let summary = self
                .paths
                .get(input.file.as_str())
                .and_then(|&id| self.file(id).summary.as_ref());
            if let Some(file) = summary {
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
        removed.iter().all(|file| self.contains_file(file))
    }

    pub(super) fn affected(
        &self,
        changed: &HashMap<String, Option<Summary>>,
        removed: &[String],
        file_count: usize,
    ) -> Option<Affected> {
        let mut new = HashMap::<&str, Vec<Name>>::new();
        for (file, summary) in changed {
            if let Some(summary) = summary {
                let file = Name::from(file.as_str());
                for key in &summary.keys {
                    let peers = new.entry(key.as_ref()).or_default();
                    if peers.last() != Some(&file) {
                        peers.push(file.clone());
                    }
                }
            }
        }
        let mut queue: VecDeque<Name> = self
            .replay
            .iter()
            .map(|&id| self.file(id).path.clone())
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
            if !files.insert(file.clone()) {
                continue;
            }
            let previous = self.paths.get(file.as_ref()).map(|&id| self.file(id));
            let old_raw = previous.and_then(|file| file.summary.as_ref());
            let incoming = changed.get(file.as_ref()).and_then(Option::as_ref);
            for key in old_raw
                .into_iter()
                .chain(incoming)
                .flat_map(|summary| &summary.keys)
                .chain(previous.into_iter().flat_map(|file| &file.owners))
            {
                if keys.insert(key.clone()) {
                    queue.extend(
                        self.keys
                            .files(key.as_ref())
                            .map(|id| self.file(id).path.clone()),
                    );
                    queue.extend(new.get(key.as_ref()).into_iter().flatten().cloned());
                }
            }
            if files.len() > file_count / 2 || keys.len() > 32_768 {
                return None;
            }
        }
        Some(Affected { files, keys })
    }

    fn remove_raw(&mut self, id: FileId) {
        if let Some(summary) = self.file_mut(id).summary.take() {
            self.file_bytes -= summary.heap_bytes();
            self.replay.remove(&id);
            for key in summary.keys {
                self.keys.remove(key.as_ref(), Relation::Raw, id);
            }
        }
    }

    pub(super) fn remove(&mut self, file: &str) {
        if let Some(&id) = self.paths.get(file) {
            self.remove_raw(id);
            self.prune(id);
        }
    }

    pub(super) fn put(&mut self, file: &str, mut summary: Summary) {
        let id = self.file_id(file);
        self.remove_raw(id);
        summary.keys.retain_mut(|text| {
            if let Some(name) = self
                .keys
                .add(text.as_ref(), Relation::Raw, id, || text.clone())
            {
                *text = name;
                true
            } else {
                false
            }
        });
        self.file_bytes += summary.heap_bytes();
        if summary.replay {
            self.replay.insert(id);
            self.replay_capacity = self.replay_capacity.max(self.replay.capacity());
        }
        self.file_mut(id).summary = Some(summary);
    }

    fn remove_owners(&mut self, file: &str) {
        if let Some(&id) = self.paths.get(file) {
            let owners = std::mem::take(&mut self.file_mut(id).owners);
            self.file_bytes -= owners.capacity() * size_of::<RecordKey>();
            for key in owners {
                self.keys.remove(key.as_ref(), Relation::Owner, id);
            }
            self.prune(id);
        }
    }

    pub(super) fn refresh_owners(
        &mut self,
        ledger: &Ledger,
        source: &str,
        revisions: Revisions,
        affected: Option<&Affected>,
        memory_limit: usize,
        cancelled: impl Fn() -> bool,
    ) -> Result<bool> {
        let sql = if let Some(affected) = affected {
            // Closure expansion visits all owner keys of each affected file.
            for file in &affected.files {
                self.remove_owners(file);
            }
            "SELECT u.record_key,u.source_file,NULL,0 FROM json_each(?1) k
             CROSS JOIN usage_records u ON u.record_key=k.value WHERE u.source_file IS NOT NULL
             UNION ALL
             SELECT t.record_key,t.source_file,coalesce(t.parser_rev,1),1 FROM json_each(?1) k
             CROSS JOIN usage_timings t ON t.record_key=k.value WHERE t.source_file IS NOT NULL"
        } else {
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
            let id = self.file_id(file);
            if let Some(key) = self
                .keys
                .add(key, Relation::Owner, id, || RecordKey::new(key))
            {
                let owners = &mut self.file_mut(id).owners;
                let before = owners.capacity();
                owners.push(key);
                self.file_bytes += (owners.capacity() - before) * size_of::<RecordKey>();
            }
            if row.get::<_, bool>(3)? && revisions.timing.is_some() {
                self.timing_current &=
                    row.get::<_, Option<i64>>(2).ok().flatten() == revisions.timing;
            }
            if self.bytes() > memory_limit {
                return Ok(false);
            }
        }
        Ok(true)
    }
}
