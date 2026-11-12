//! Multi-source refresh owner. The state mutex linearizes every disk commit with cancellation.
use std::collections::{BTreeMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use fs2::FileExt;
use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::api::news::{plain_text, safe_url, NewsError, NewsItem, NewsSnapshot, SourceState};
use crate::sources::{Category, ItemKind, PopularityKind, RawItem, Source};

const MAX_ITEMS: usize = 50;
const MAX_CACHE_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Default, Serialize, Deserialize)]
pub(crate) struct SourceCache {
    pub items: Vec<NewsItem>,
    pub last_success_ms: Option<i64>,
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Cache {
    pub version: u32,
    pub sources: BTreeMap<String, SourceCache>,
    pub disabled: Vec<String>,
}

impl Default for Cache {
    fn default() -> Self {
        Self {
            version: 2,
            sources: BTreeMap::new(),
            disabled: Vec::new(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct NewsEngine {
    inner: Arc<Inner>,
}

struct Inner {
    sources: Vec<Arc<dyn Source>>,
    http: Client,
    cache_path: PathBuf,
    state: Mutex<State>,
}

struct State {
    cache: Cache,
    sources: Vec<SourceState>,
    error: Option<NewsError>,
    active: Option<(u64, CancellationToken)>,
    next_id: u64,
    closed: bool,
    lock: Option<File>,
}

impl NewsEngine {
    pub(crate) fn new(data_dir: &Path, sources: Vec<Box<dyn Source>>) -> Result<Self, String> {
        Self::open(data_dir, sources, Duration::from_secs(20))
    }

    pub(crate) fn open(
        data_dir: &Path,
        sources: Vec<Box<dyn Source>>,
        timeout: Duration,
    ) -> Result<Self, String> {
        if !data_dir.is_absolute() {
            return Err("cache: data_dir must be an explicit absolute path.".into());
        }
        let mut ids = HashSet::new();
        if sources
            .iter()
            .any(|s| s.info().id.is_empty() || !ids.insert(s.info().id))
        {
            return Err("cache: Registry source ids must be nonempty and unique.".into());
        }
        std::fs::create_dir_all(data_dir).map_err(|_| "cache: Cannot create cache directory.")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(data_dir.join("news.lock"))
            .map_err(|_| "cache: Cannot open cache lock.")?;
        lock.try_lock_exclusive()
            .map_err(|_| "busy: Cache directory is in use.")?;
        let cache_path = data_dir.join("news-cache.json");
        let (cache, error) =
            match load_cache(&cache_path, &sources, chrono::Utc::now().timestamp_millis()) {
                Ok(cache) => (cache, None),
                Err(err) => (Cache::default(), Some(err)),
            };
        let states = sources
            .iter()
            .map(|source| {
                let info = source.info();
                SourceState {
                    enabled: !cache.disabled.contains(&info.id),
                    last_success_ms: cache.sources.get(&info.id).and_then(|c| c.last_success_ms),
                    id: info.id,
                    name: info.name,
                    category: info.category.as_str().into(),
                    home_url: info.home_url,
                    refreshing: false,
                    error: None,
                }
            })
            .collect();
        let http = Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .user_agent("TokenLens-News/0.1")
            .build()
            .map_err(|_| "network: Cannot initialize HTTP client.")?;
        Ok(Self {
            inner: Arc::new(Inner {
                sources: sources.into_iter().map(Arc::from).collect(),
                http,
                cache_path,
                state: Mutex::new(State {
                    cache,
                    sources: states,
                    error,
                    active: None,
                    next_id: 0,
                    closed: false,
                    lock: Some(lock),
                }),
            }),
        })
    }

    pub(crate) fn snapshot(&self) -> NewsSnapshot {
        assemble(&self.inner.state.lock().unwrap())
    }

    pub(crate) async fn refresh(&self, source_ids: Option<Vec<String>>) -> NewsSnapshot {
        let (generation, token, selected) = {
            let mut state = self.inner.state.lock().unwrap();
            if state.closed {
                return snapshot_error(&state, "closed", "News client is closed.");
            }
            if state.active.is_some() {
                return snapshot_error(&state, "busy", "A refresh is already running.");
            }
            let selected: Vec<usize> = state
                .sources
                .iter()
                .enumerate()
                .filter(|(_, s)| {
                    s.enabled && source_ids.as_ref().is_none_or(|ids| ids.contains(&s.id))
                })
                .map(|(i, _)| i)
                .collect();
            state.error = None;
            if selected.is_empty() {
                return assemble(&state);
            }
            state.next_id += 1;
            let generation = state.next_id;
            let token = CancellationToken::new();
            state.active = Some((generation, token.clone()));
            for &i in &selected {
                state.sources[i].refreshing = true;
            }
            (generation, token, selected)
        };
        let _guard = RefreshGuard {
            inner: self.inner.clone(),
            generation,
        };
        let mut tasks = JoinSet::new();
        let mut pending = selected.into_iter();
        let now_ms = chrono::Utc::now().timestamp_millis();
        'refresh: loop {
            while tasks.len() < 4 {
                let Some(index) = pending.next() else {
                    break;
                };
                let mut state = self.inner.state.lock().unwrap();
                if state.closed || state.active.as_ref().map(|v| v.0) != Some(generation) {
                    break 'refresh;
                }
                if !state.sources[index].enabled {
                    state.sources[index].refreshing = false;
                    continue;
                }
                let inner = self.inner.clone();
                let task_token = token.clone();
                tasks.spawn(async move {
                    let result = tokio::select! { biased;
                        _ = task_token.cancelled() => Err(error("cancelled", "Refresh cancelled.")),
                        result = inner.fetch(index, now_ms) => result,
                    };
                    (index, result)
                });
            }
            if tasks.is_empty() {
                break;
            }
            let result = tokio::select! { biased;
                _ = token.cancelled() => { break; }
                result = tasks.join_next() => result,
            };
            let Some(result) = result else {
                break;
            };
            match result {
                Ok((index, result)) => self.inner.commit(
                    generation,
                    index,
                    result,
                    chrono::Utc::now().timestamp_millis(),
                ),
                Err(_) => {
                    let mut state = self.inner.state.lock().unwrap();
                    if state.active.as_ref().map(|v| v.0) == Some(generation) {
                        cancel_active(&mut state, "A source refresh was interrupted.");
                    }
                    break;
                }
            }
            if token.is_cancelled() {
                break;
            }
        }
        // Abort and drain the owned request tasks before normal completion/cancellation returns.
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        let mut state = self.inner.state.lock().unwrap();
        if state.active.as_ref().map(|v| v.0) == Some(generation) {
            state.active = None;
            for source in &mut state.sources {
                source.refreshing = false;
            }
        }
        assemble(&state)
    }

    pub(crate) fn set_source_enabled(&self, id: &str, enabled: bool) -> NewsSnapshot {
        let mut state = self.inner.state.lock().unwrap();
        if state.closed {
            return snapshot_error(&state, "closed", "News client is closed.");
        }
        let Some(index) = state.sources.iter().position(|s| s.id == id) else {
            return assemble(&state);
        };
        if state.sources[index].enabled == enabled {
            return assemble(&state);
        }
        let mut cache = state.cache.clone();
        cache.disabled.retain(|v| v != id);
        if !enabled {
            cache.disabled.push(id.into());
        }
        match save_cache(&self.inner.cache_path, &cache) {
            Ok(()) => {
                state.cache = cache;
                state.sources[index].enabled = enabled;
                state.error = None;
            }
            Err(err) => state.error = Some(err),
        }
        assemble(&state)
    }

    pub(crate) fn cancel_refresh(&self) {
        let mut state = self.inner.state.lock().unwrap();
        cancel_active(&mut state, "Refresh cancelled.");
    }

    pub(crate) fn shutdown(&self) {
        let mut state = self.inner.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.closed = true;
        cancel_active(&mut state, "Refresh cancelled.");
        state.error = Some(error("closed", "News client is closed."));
        state.lock.take();
    }
}

impl Inner {
    async fn fetch(&self, index: usize, now_ms: i64) -> Result<Vec<NewsItem>, NewsError> {
        let source = &self.sources[index];
        let max_bytes = source.max_body_bytes();
        let too_large = || error("too_large", "Source response exceeds its size limit.");
        let mut response = self
            .http
            .get(source.url(now_ms))
            .send()
            .await
            .map_err(http_error)?;
        let status = response.status().as_u16();
        let source_id = source.info().id;
        if status == 429
            || (status == 403
                && (source_id.starts_with("gh-release:") || source_id == "github-new")
                && response
                    .headers()
                    .get("x-ratelimit-remaining")
                    .is_some_and(|v| v == "0"))
        {
            return Err(error(
                "rate_limited",
                "Source rate limit reached. Try again later.",
            ));
        }
        if status != 200 {
            return Err(error("http", &format!("Source returned HTTP {status}.")));
        }
        if let Some(content_type) = response.headers().get(reqwest::header::CONTENT_TYPE) {
            let mime = content_type
                .to_str()
                .ok()
                .and_then(|s| s.split(';').next())
                .map(|s| s.trim().to_ascii_lowercase());
            if !mime
                .as_ref()
                .is_some_and(|m| source.accepts().iter().any(|prefix| m.starts_with(prefix)))
            {
                return Err(error(
                    "content_type",
                    "Response has an unsupported content type.",
                ));
            }
        }
        if response
            .content_length()
            .is_some_and(|v| v > max_bytes as u64)
        {
            return Err(too_large());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http_error)? {
            if body.len() + chunk.len() > max_bytes {
                return Err(too_large());
            }
            body.extend_from_slice(&chunk);
        }
        let raw = source
            .parse(&body)
            .map_err(|_| error("parse", "Cannot parse this source's news response."))?;
        let info = source.info();
        normalise_items(
            &info.id,
            raw,
            source.text_is_html(),
            info.category,
            source.default_kind(),
            source.ai_summary(),
        )
    }

    fn commit(
        &self,
        generation: u64,
        index: usize,
        result: Result<Vec<NewsItem>, NewsError>,
        now_ms: i64,
    ) {
        let mut state = self.state.lock().unwrap();
        if state.closed || state.active.as_ref().map(|v| v.0) != Some(generation) {
            return;
        }
        state.sources[index].refreshing = false;
        if !state.sources[index].enabled {
            return;
        }
        match result {
            Ok(mut items) => {
                let mut cache = state.cache.clone();
                stamp_first_seen(
                    &mut items,
                    cache.sources.get(&state.sources[index].id),
                    now_ms,
                );
                cache.sources.insert(
                    state.sources[index].id.clone(),
                    SourceCache {
                        items,
                        last_success_ms: Some(now_ms),
                    },
                );
                match save_cache(&self.cache_path, &cache) {
                    Ok(()) => {
                        state.cache = cache;
                        state.sources[index].last_success_ms = Some(now_ms);
                        state.sources[index].error = None;
                    }
                    Err(err) => state.error = Some(err),
                }
            }
            Err(err) => state.sources[index].error = Some(err),
        }
    }
}

fn stamp_first_seen(items: &mut [NewsItem], previous: Option<&SourceCache>, now_ms: i64) {
    let seen: BTreeMap<_, _> = previous
        .into_iter()
        .flat_map(|cache| &cache.items)
        .map(|item| (item.id.as_str(), item.first_seen_ms))
        .collect();
    for item in items {
        item.first_seen_ms = seen.get(item.id.as_str()).copied().unwrap_or_else(|| {
            if previous.is_none() {
                first_seen_fallback(item.published_at.as_deref(), Some(now_ms), now_ms)
            } else {
                now_ms
            }
        });
    }
}

fn first_seen_fallback(
    published_at: Option<&str>,
    last_success_ms: Option<i64>,
    now_ms: i64,
) -> i64 {
    let published_ms = published_at
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis());
    match (published_ms, last_success_ms) {
        (Some(published), Some(success)) => published.min(success),
        (Some(time), None) | (None, Some(time)) => time,
        (None, None) => now_ms,
    }
}

struct RefreshGuard {
    inner: Arc<Inner>,
    generation: u64,
}
impl Drop for RefreshGuard {
    fn drop(&mut self) {
        let mut state = self.inner.state.lock().unwrap();
        if state.active.as_ref().map(|v| v.0) == Some(self.generation) {
            cancel_active(&mut state, "Refresh future was dropped.");
        }
    }
}

fn cancel_active(state: &mut State, message: &str) {
    if let Some((_, token)) = state.active.take() {
        token.cancel();
        for source in &mut state.sources {
            if source.refreshing {
                source.refreshing = false;
                source.error = Some(error("cancelled", message));
            }
        }
    }
}

fn literal_text(raw: &str, limit: usize) -> String {
    raw.chars()
        .filter(|c| !c.is_control() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(limit)
        .collect()
}

fn keyword_kind(title: &str, category: Category) -> Option<ItemKind> {
    if !matches!(category, Category::Official | Category::Tools) {
        return None;
    }
    let title = title.to_lowercase();
    let word_char = |c: char| c.is_ascii_alphanumeric() || c == '_';
    for (kind, keywords) in [
        (
            ItemKind::Deprecation,
            &[
                "deprecate",
                "deprecated",
                "deprecation",
                "retire",
                "retired",
                "retirement",
                "retiring",
                "shut down",
                "shutdown",
                "sunset",
                "end of life",
                "弃用",
                "下线",
                "停用",
                "退役",
            ][..],
        ),
        (
            ItemKind::Pricing,
            &[
                "price", "prices", "pricing", "priced", "价格", "定价", "降价", "涨价", "计费",
            ][..],
        ),
    ] {
        if keywords.iter().any(|keyword| {
            title.match_indices(keyword).any(|(start, matched)| {
                !keyword.is_ascii()
                    || (!title[..start].chars().next_back().is_some_and(word_char)
                        && !title[start + matched.len()..]
                            .chars()
                            .next()
                            .is_some_and(word_char))
            })
        }) {
            return Some(kind);
        }
    }
    None
}

pub(crate) fn normalise_items(
    source_id: &str,
    raw: Vec<RawItem>,
    text_is_html: bool,
    category: Category,
    default_kind: ItemKind,
    ai_summary: bool,
) -> Result<Vec<NewsItem>, NewsError> {
    let normalise_text: fn(&str, usize) -> String = if text_is_html {
        plain_text
    } else {
        literal_text
    };
    let had_items = !raw.is_empty();
    let mut items = Vec::new();
    let mut ids = HashSet::new();
    for item in raw {
        let Some(url) = safe_url(&item.url) else {
            continue;
        };
        let title = normalise_text(&item.title, 512);
        if title.is_empty()
            || item.native_id.is_empty()
            || item.native_id.chars().count() > 8192
            || !ids.insert(item.native_id.clone())
        {
            continue;
        }
        let description = item
            .description
            .map(|s| normalise_text(&s, 4000))
            .filter(|s| !s.is_empty());
        let published_at = item
            .published_at
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
            .map(|d| {
                d.with_timezone(&chrono::Utc)
                    .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true)
            });
        let (popularity_kind, popularity) = item
            .popularity
            .map(|p| {
                (
                    Some(
                        match p.kind {
                            PopularityKind::Points => "points",
                            PopularityKind::Stars => "stars",
                            PopularityKind::Likes => "likes",
                            PopularityKind::Upvotes => "upvotes",
                        }
                        .into(),
                    ),
                    Some(p.value),
                )
            })
            .unwrap_or_default();
        let kind = keyword_kind(&title, category)
            .or(item.kind)
            .unwrap_or(default_kind);
        items.push(NewsItem {
            ai_summary,
            origin: item
                .origin
                .map(|s| literal_text(&s, 120))
                .filter(|s| !s.is_empty()),
            // Assigned under the state lock when this source successfully commits.
            first_seen_ms: 0,
            kind: kind.as_str().into(),
            id: format!("{source_id}:{}", item.native_id),
            source_id: source_id.into(),
            title,
            url,
            published_at,
            description,
            popularity_kind,
            popularity,
            also_in: Vec::new(),
        });
    }
    if had_items && items.is_empty() {
        return Err(error("parse", "Source contained no valid news items."));
    }
    items.sort_by_cached_key(|item| std::cmp::Reverse(item_time(item)));
    items.truncate(MAX_ITEMS);
    Ok(items)
}

fn item_time(item: &NewsItem) -> Option<chrono::DateTime<chrono::FixedOffset>> {
    item.published_at
        .as_ref()
        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
}

fn compare_items(a: &NewsItem, b: &NewsItem) -> std::cmp::Ordering {
    b.first_seen_ms
        .cmp(&a.first_seen_ms)
        .then_with(|| item_time(b).cmp(&item_time(a)))
}

fn canonical_url(raw: &str) -> String {
    let mut url = Url::parse(raw).expect("validated news URL");
    url.set_fragment(None);
    let pairs: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(key, _)| !key.starts_with("utm_"))
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    url.set_query(None);
    if !pairs.is_empty() {
        url.query_pairs_mut().extend_pairs(pairs);
    }
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(&path);
    // Url serializes an empty HTTP path as '/', which is the same canonical root.
    url.to_string()
}

fn assemble(state: &State) -> NewsSnapshot {
    let mut ordered: Vec<_> = state
        .sources
        .iter()
        .enumerate()
        .filter(|(_, s)| s.enabled)
        .collect();
    ordered.sort_by_key(|(index, source)| {
        (
            source.id == "aihot",
            match source.category.as_str() {
                "official" => 0,
                "chinese" => 1,
                "tools" => 2,
                _ => 3,
            },
            *index,
        )
    });
    let mut items: Vec<(usize, NewsItem)> = Vec::new();
    let mut urls = BTreeMap::new();
    for (index, source) in ordered {
        if let Some(cache) = state.cache.sources.get(&source.id) {
            let mut sorted: Vec<_> = cache.items.iter().collect();
            sorted.sort_by(|a, b| compare_items(a, b));
            for item in sorted {
                let key = canonical_url(&item.url);
                if let Some(&position) = urls.get(&key) {
                    let (_, kept): &mut (usize, NewsItem) = &mut items[position];
                    if kept.source_id != source.id {
                        kept.first_seen_ms = kept.first_seen_ms.min(item.first_seen_ms);
                        if !kept.also_in.contains(&source.id) {
                            kept.also_in.push(source.id.clone());
                        }
                        continue;
                    }
                } else {
                    urls.insert(key, items.len());
                }
                items.push((index, item.clone()));
            }
        }
    }
    items.sort_by(|(ia, a), (ib, b)| compare_items(a, b).then(ia.cmp(ib)));
    NewsSnapshot {
        sources: state.sources.clone(),
        items: items.into_iter().map(|(_, item)| item).collect(),
        refreshing: state.active.is_some(),
        error: state.error.clone(),
    }
}

fn snapshot_error(state: &State, kind: &str, message: &str) -> NewsSnapshot {
    NewsSnapshot {
        error: Some(error(kind, message)),
        ..assemble(state)
    }
}

pub(crate) fn error(kind: &str, message: &str) -> NewsError {
    NewsError {
        kind: kind.into(),
        message: message.into(),
    }
}
fn http_error(err: reqwest::Error) -> NewsError {
    if err.is_timeout() {
        error("timeout", "News request timed out.")
    } else {
        error(
            "network",
            "Cannot fetch news. Check your connection and retry.",
        )
    }
}

fn valid_text(value: &str, limit: usize) -> bool {
    value.chars().count() <= limit && !value.chars().any(char::is_control)
}

fn load_cache(path: &Path, sources: &[Box<dyn Source>], now_ms: i64) -> Result<Cache, NewsError> {
    let invalid = || {
        error(
            "cache",
            "News cache is corrupt or has an unsupported version. Refresh to replace it.",
        )
    };
    let file = match File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Cache::default()),
        Err(_) => return Err(error("cache", "Cannot read the news cache.")),
    };
    let mut bytes = Vec::new();
    file.take((MAX_CACHE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() > MAX_CACHE_BYTES {
        return Err(invalid());
    }
    let mut json: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    let cache: Cache = match json.get("version").and_then(|v| v.as_u64()) {
        Some(2) => {
            if let Some(cached_sources) = json.get_mut("sources").and_then(|v| v.as_object_mut()) {
                for (id, cached) in cached_sources {
                    let last_success_ms = cached.get("last_success_ms").and_then(|v| v.as_i64());
                    let default_kind = sources
                        .iter()
                        .find(|s| s.info().id == *id)
                        .map_or(ItemKind::General, |s| s.default_kind());
                    if let Some(items) = cached.get_mut("items").and_then(|v| v.as_array_mut()) {
                        for item in items {
                            if let Some(fields) = item.as_object_mut() {
                                let first_seen_ms = first_seen_fallback(
                                    fields.get("published_at").and_then(|v| v.as_str()),
                                    last_success_ms,
                                    now_ms,
                                );
                                fields
                                    .entry("first_seen_ms")
                                    .or_insert_with(|| first_seen_ms.into());
                                fields.entry("ai_summary").or_insert_with(|| false.into());
                                fields.entry("origin").or_insert(serde_json::Value::Null);
                                fields
                                    .entry("kind")
                                    .or_insert_with(|| default_kind.as_str().into());
                            }
                        }
                    }
                }
            }
            serde_json::from_value(json).map_err(|_| invalid())?
        }
        Some(1) => {
            #[derive(Deserialize)]
            struct LegacyItem {
                id: String,
                title: String,
                url: String,
                published_at: Option<String>,
                description: Option<String>,
            }
            #[derive(Deserialize)]
            struct Legacy {
                items: Vec<LegacyItem>,
                last_success_ms: i64,
            }
            let legacy: Legacy = serde_json::from_value(json).map_err(|_| invalid())?;
            if legacy.last_success_ms < 0 || legacy.items.len() > 100 {
                return Err(invalid());
            }
            let mut identities = HashSet::new();
            let mut items = Vec::new();
            for item in legacy.items {
                if item.id.is_empty()
                    || item.id.chars().count() > 2048
                    || !identities.insert(item.id.clone())
                {
                    return Err(invalid());
                }
                items.push(NewsItem {
                    ai_summary: false,
                    origin: None,
                    first_seen_ms: first_seen_fallback(
                        item.published_at.as_deref(),
                        Some(legacy.last_success_ms),
                        now_ms,
                    ),
                    kind: ItemKind::General.as_str().into(),
                    id: format!("openai:{}", item.id),
                    source_id: "openai".into(),
                    title: item.title,
                    url: item.url,
                    published_at: item.published_at,
                    description: item.description,
                    popularity_kind: None,
                    popularity: None,
                    also_in: Vec::new(),
                });
            }
            for item in &items {
                validate_cached_item("openai", item).map_err(|_| invalid())?;
            }
            items.sort_by_cached_key(|item| std::cmp::Reverse(item_time(item)));
            items.truncate(MAX_ITEMS);
            Cache {
                sources: BTreeMap::from([(
                    "openai".into(),
                    SourceCache {
                        items,
                        last_success_ms: Some(legacy.last_success_ms),
                    },
                )]),
                ..Cache::default()
            }
        }
        _ => return Err(invalid()),
    };
    if cache.disabled.iter().any(|id| id.is_empty())
        || cache.disabled.iter().collect::<HashSet<_>>().len() != cache.disabled.len()
    {
        return Err(invalid());
    }
    for (id, source) in &cache.sources {
        if id.is_empty()
            || source.items.len() > MAX_ITEMS
            || source.last_success_ms.is_some_and(|n| n < 0)
        {
            return Err(invalid());
        }
        let mut identities = HashSet::new();
        for item in &source.items {
            validate_cached_item(id, item).map_err(|_| invalid())?;
            if !identities.insert(&item.id) {
                return Err(invalid());
            }
        }
    }
    Ok(cache)
}

fn validate_cached_item(source: &str, item: &NewsItem) -> Result<(), ()> {
    if item.first_seen_ms <= 0
        || (item.ai_summary && source != "aihot")
        || item
            .origin
            .as_ref()
            .is_some_and(|s| s.is_empty() || !valid_text(s, 120))
        || ![
            ItemKind::Release,
            ItemKind::Api,
            ItemKind::Deprecation,
            ItemKind::Pricing,
            ItemKind::Model,
            ItemKind::General,
        ]
        .iter()
        .any(|kind| kind.as_str() == item.kind)
        || item.source_id != source
        || !item.id.starts_with(&format!("{source}:"))
        || item.id.len() <= source.len() + 1
        || item.id.chars().count() > source.chars().count() + 8193
        || !item.also_in.is_empty()
        || item.title.is_empty()
        || !valid_text(&item.title, 512)
        || safe_url(&item.url).as_deref() != Some(&item.url)
        || item
            .description
            .as_ref()
            .is_some_and(|s| !valid_text(s, 4000))
        || item
            .published_at
            .as_ref()
            .is_some_and(|s| chrono::DateTime::parse_from_rfc3339(s).is_err())
        || !matches!(
            (item.popularity_kind.as_deref(), item.popularity),
            (None, None) | (Some("points" | "stars" | "likes" | "upvotes"), Some(_))
        )
    {
        return Err(());
    }
    Ok(())
}

pub(crate) fn prepare_cache<T: Serialize>(
    path: &Path,
    cache: &T,
) -> Result<tempfile::NamedTempFile, NewsError> {
    let failed = || {
        error(
            "cache",
            "Cannot save the news cache. Previous cache was preserved.",
        )
    };
    let mut temp = tempfile::NamedTempFile::new_in(path.parent().unwrap()).map_err(|_| failed())?;
    serde_json::to_writer(&mut temp, cache).map_err(|_| failed())?;
    if temp.as_file().metadata().map_err(|_| failed())?.len() > MAX_CACHE_BYTES as u64 {
        return Err(failed());
    }
    temp.flush().map_err(|_| failed())?;
    temp.as_file().sync_all().map_err(|_| failed())?;
    Ok(temp)
}

pub(crate) fn replace_cache(path: &Path, temp: tempfile::NamedTempFile) -> Result<(), NewsError> {
    // tempfile uses atomic replace on Windows as well; the old file is never removed first.
    temp.persist(path).map_err(|_| {
        error(
            "cache",
            "Cannot save the news cache. Previous cache was preserved.",
        )
    })?;
    Ok(())
}

fn save_cache(path: &Path, cache: &Cache) -> Result<(), NewsError> {
    replace_cache(path, prepare_cache(path, cache)?)
}

#[cfg(test)]
mod tests;
