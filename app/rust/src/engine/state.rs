use super::*;

const READ_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct StarredItem {
    pub starred_at_ms: i64,
    pub item: NewsItem,
}

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct ItemState {
    version: u32,
    pub read: BTreeMap<String, i64>,
    pub starred: BTreeMap<String, StarredItem>,
}

impl Default for ItemState {
    fn default() -> Self {
        Self {
            version: 1,
            read: BTreeMap::new(),
            starred: BTreeMap::new(),
        }
    }
}

pub(super) fn load(path: &Path) -> Result<ItemState, NewsError> {
    let invalid = || {
        error("cache", "News state is corrupt or has an unsupported version. Read and starred state is unavailable.")
    };
    let file = match File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(ItemState::default()),
        Err(_) => return Err(error("cache", "Cannot read the news state.")),
    };
    let mut bytes = Vec::new();
    file.take((MAX_CACHE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() > MAX_CACHE_BYTES {
        return Err(invalid());
    }
    let state: ItemState = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if state.version != 1
        || state
            .read
            .iter()
            .any(|(id, time)| id.is_empty() || *time < 0)
    {
        return Err(invalid());
    }
    for (id, entry) in &state.starred {
        // Cache validation forbids also_in; a saved snapshot deliberately includes it.
        let mut item = entry.item.clone();
        item.also_in.clear();
        if entry.starred_at_ms < 0
            || *id != item.id
            || entry
                .item
                .also_in
                .iter()
                .any(|s| s.is_empty() || *s == item.source_id)
            || entry.item.also_in.iter().collect::<HashSet<_>>().len() != entry.item.also_in.len()
            || validate_cached_item(&item.source_id, &item).is_err()
        {
            return Err(invalid());
        }
    }
    Ok(state)
}

pub(super) fn save(
    path: &Path,
    candidate: &mut ItemState,
    cache: &Cache,
    now_ms: i64,
) -> Result<(), NewsError> {
    let cached: HashSet<_> = cache
        .sources
        .values()
        .flat_map(|s| s.items.iter().map(|i| i.id.as_str()))
        .collect();
    let cutoff = now_ms.saturating_sub(READ_RETENTION_MS);
    candidate
        .read
        .retain(|id, at| *at >= cutoff || cached.contains(id.as_str()));
    replace_cache(path, prepare_cache(path, candidate)?).map_err(|_| {
        error(
            "cache",
            "Cannot save the news state. Previous state was preserved.",
        )
    })
}
