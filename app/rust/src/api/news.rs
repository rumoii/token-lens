use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use fs2::FileExt;
use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

const FEED_URL: &str = "https://openai.com/news/rss.xml";
const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_ITEMS: usize = 100;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewsItem {
    pub id: String,
    pub title: String,
    pub url: String,
    pub published_at: Option<String>,
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewsError {
    pub kind: String,
    pub message: String,
}

#[derive(Clone, Debug, Default)]
pub struct NewsSnapshot {
    pub items: Vec<NewsItem>,
    pub last_success_ms: Option<i64>,
    pub refreshing: bool,
    pub error: Option<NewsError>,
}

#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct NewsClient {
    inner: Arc<Inner>,
}

struct Inner {
    state: Mutex<State>,
    http: Client,
    endpoint: String,
    cache_path: PathBuf,
}

struct State {
    snapshot: NewsSnapshot,
    active: Option<(u64, CancellationToken)>,
    next_id: u64,
    closed: bool,
    lock: Option<File>,
}

#[derive(Serialize, Deserialize)]
struct Cache {
    version: u32,
    items: Vec<NewsItem>,
    last_success_ms: i64,
}

impl NewsClient {
    /// Opens only the explicit cache directory. Network requests require refresh().
    pub fn new(data_dir: String) -> Result<NewsClient, String> {
        Self::open(
            Path::new(&data_dir),
            FEED_URL.to_owned(),
            Duration::from_secs(20),
        )
    }

    pub fn snapshot(&self) -> NewsSnapshot {
        self.inner.state.lock().unwrap().snapshot.clone()
    }

    pub async fn refresh(&self) -> NewsSnapshot {
        let (id, token) = {
            let mut state = self.inner.state.lock().unwrap();
            if state.closed {
                return with_error(&state.snapshot, "closed", "News client is closed.");
            }
            if state.active.is_some() {
                return with_error(&state.snapshot, "busy", "A refresh is already running.");
            }
            state.next_id += 1;
            let id = state.next_id;
            let token = CancellationToken::new();
            state.active = Some((id, token.clone()));
            state.snapshot.refreshing = true;
            state.snapshot.error = None;
            (id, token)
        };
        let _guard = RefreshGuard {
            inner: self.inner.clone(),
            id,
        };
        let result = tokio::select! {
            biased;
            _ = token.cancelled() => Err(error("cancelled", "Refresh cancelled.")),
            result = self.inner.fetch() => result,
        };
        let prepared = result.and_then(|items| {
            let cache = Cache {
                version: 1,
                items,
                last_success_ms: chrono::Utc::now().timestamp_millis(),
            };
            let temp = prepare_cache(&self.inner.cache_path, &cache)?;
            Ok((cache, temp))
        });
        // Cancellation, shutdown, and the commit share one linearization point.
        let mut state = self.inner.state.lock().unwrap();
        if state.closed || state.active.as_ref().map(|v| v.0) != Some(id) {
            return state.snapshot.clone();
        }
        state.active = None;
        state.snapshot.refreshing = false;
        match prepared {
            Ok((cache, temp)) => match replace_cache(&self.inner.cache_path, temp) {
                Ok(()) => {
                    state.snapshot.items = cache.items;
                    state.snapshot.last_success_ms = Some(cache.last_success_ms);
                    state.snapshot.error = None;
                }
                Err(err) => state.snapshot.error = Some(err),
            },
            Err(err) => state.snapshot.error = Some(err),
        }
        state.snapshot.clone()
    }

    pub fn cancel_refresh(&self) {
        let mut state = self.inner.state.lock().unwrap();
        if let Some((_, token)) = state.active.take() {
            token.cancel();
            state.snapshot.refreshing = false;
            state.snapshot.error = Some(error("cancelled", "Refresh cancelled."));
        }
    }

    pub fn shutdown(&self) {
        let mut state = self.inner.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.closed = true;
        if let Some((_, token)) = state.active.take() {
            token.cancel();
        }
        state.snapshot.refreshing = false;
        state.snapshot.error = Some(error("closed", "News client is closed."));
        state.lock.take();
    }
}

impl NewsClient {
    fn open(data_dir: &Path, endpoint: String, timeout: Duration) -> Result<Self, String> {
        if !data_dir.is_absolute() {
            return Err("cache: data_dir must be an explicit absolute path.".to_owned());
        }
        std::fs::create_dir_all(data_dir)
            .map_err(|_| "cache: Cannot create cache directory.".to_owned())?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(data_dir.join("news.lock"))
            .map_err(|_| "cache: Cannot open cache lock.".to_owned())?;
        lock.try_lock_exclusive()
            .map_err(|_| "busy: Cache directory is in use.".to_owned())?;
        let cache_path = data_dir.join("news-cache.json");
        let snapshot = match load_cache(&cache_path) {
            Ok(Some(cache)) => NewsSnapshot {
                items: cache.items,
                last_success_ms: Some(cache.last_success_ms),
                ..Default::default()
            },
            Ok(None) => NewsSnapshot::default(),
            Err(err) => NewsSnapshot {
                error: Some(err),
                ..Default::default()
            },
        };
        let http = Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .user_agent("TokenLens-News/0.1")
            .build()
            .map_err(|_| "network: Cannot initialize HTTP client.".to_owned())?;
        Ok(Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State {
                    snapshot,
                    active: None,
                    next_id: 0,
                    closed: false,
                    lock: Some(lock),
                }),
                http,
                endpoint,
                cache_path,
            }),
        })
    }

    #[cfg(test)]
    fn new_for_test(data_dir: &Path, endpoint: String, timeout: Duration) -> Result<Self, String> {
        Self::open(data_dir, endpoint, timeout)
    }
}

impl Inner {
    async fn fetch(&self) -> Result<Vec<NewsItem>, NewsError> {
        let mut response = self
            .http
            .get(&self.endpoint)
            .send()
            .await
            .map_err(http_error)?;
        if response.status().as_u16() == 429 {
            return Err(error(
                "rate_limited",
                "OpenAI News returned HTTP 429. Try again later.",
            ));
        }
        if !response.status().is_success() {
            return Err(error(
                "network",
                &format!("OpenAI News returned HTTP {}.", response.status().as_u16()),
            ));
        }
        if let Some(content_type) = response.headers().get(reqwest::header::CONTENT_TYPE) {
            let mime = content_type
                .to_str()
                .ok()
                .and_then(|value| value.split(';').next())
                .map(|value| value.trim().to_ascii_lowercase());
            if !matches!(
                mime.as_deref(),
                Some("application/rss+xml" | "application/xml" | "text/xml")
            ) {
                return Err(error(
                    "parse",
                    "Response has an unsupported RSS content type.",
                ));
            }
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_BYTES as u64)
        {
            return Err(error("parse", "Feed exceeds the 4 MiB limit."));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http_error)? {
            if body.len() + chunk.len() > MAX_BYTES {
                return Err(error("parse", "Feed exceeds the 4 MiB limit."));
            }
            body.extend_from_slice(&chunk);
        }
        parse_feed(&body)
    }
}

struct RefreshGuard {
    inner: Arc<Inner>,
    id: u64,
}

impl Drop for RefreshGuard {
    fn drop(&mut self) {
        let mut state = self.inner.state.lock().unwrap();
        if state.active.as_ref().map(|v| v.0) == Some(self.id) {
            state.active.take().unwrap().1.cancel();
            state.snapshot.refreshing = false;
            state.snapshot.error = Some(error("cancelled", "Refresh future was dropped."));
        }
    }
}

fn error(kind: &str, message: &str) -> NewsError {
    NewsError {
        kind: kind.to_owned(),
        message: message.to_owned(),
    }
}

fn with_error(snapshot: &NewsSnapshot, kind: &str, message: &str) -> NewsSnapshot {
    NewsSnapshot {
        error: Some(error(kind, message)),
        ..snapshot.clone()
    }
}

fn http_error(err: reqwest::Error) -> NewsError {
    if err.is_timeout() {
        error("timeout", "OpenAI News request timed out.")
    } else {
        error(
            "network",
            "Cannot fetch OpenAI News. Check your connection and retry.",
        )
    }
}

fn safe_url(raw: &str) -> Option<String> {
    let url = Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || raw.len() > 8192
        || url.as_str().len() > 8192
    {
        return None;
    }
    Some(url.to_string())
}

fn plain_text(raw: &str, limit: usize) -> String {
    let fragment = scraper::Html::parse_fragment(raw);
    let mut value = String::new();
    for node in fragment.tree.nodes() {
        if let scraper::Node::Text(text) = node.value() {
            let hidden = node.ancestors().any(|ancestor| {
                ancestor.value().as_element().is_some_and(|v| {
                    matches!(v.name(), "script" | "style" | "noscript" | "template")
                })
            });
            if !hidden {
                value.push_str(text);
                value.push(' ');
            }
        }
    }
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(limit)
        .collect()
}

fn parse_feed(bytes: &[u8]) -> Result<Vec<NewsItem>, NewsError> {
    let invalid = || error("parse", "Response is not a valid RSS news feed.");
    let input = std::str::from_utf8(bytes).map_err(|_| invalid())?;
    let document = roxmltree::Document::parse(input).map_err(|_| invalid())?;
    let root = document.root_element();
    if root.tag_name().name() != "rss" || root.attribute("version") != Some("2.0") {
        return Err(invalid());
    }
    let channels: Vec<_> = root
        .children()
        .filter(|v| v.is_element() && v.tag_name().name() == "channel")
        .collect();
    if channels.len() != 1 {
        return Err(invalid());
    }
    let channel = channels[0];
    let child = |node: roxmltree::Node<'_, '_>, name: &str| -> String {
        node.children()
            .find(|v| v.is_element() && v.tag_name().name() == name)
            .and_then(|v| v.text())
            .unwrap_or("")
            .trim()
            .to_owned()
    };
    if child(channel, "title").is_empty()
        || safe_url(&child(channel, "link")).is_none()
        || child(channel, "description").is_empty()
    {
        return Err(invalid());
    }
    let mut items = Vec::new();
    let mut saw_item = false;
    for node in channel
        .children()
        .filter(|v| v.is_element() && v.tag_name().name() == "item")
    {
        saw_item = true;
        let Some(url) = safe_url(&child(node, "link")) else {
            continue;
        };
        let title = plain_text(&child(node, "title"), 512);
        if title.is_empty() {
            continue;
        }
        let guid = child(node, "guid");
        let id = if guid.is_empty() {
            url.clone()
        } else {
            guid.chars().take(2048).collect()
        };
        let published_at = chrono::DateTime::parse_from_rfc2822(&child(node, "pubDate"))
            .ok()
            .map(|v| v.to_rfc3339());
        let description = plain_text(&child(node, "description"), 4000);
        items.push(NewsItem {
            id,
            title,
            url,
            published_at,
            description: if description.is_empty() {
                None
            } else {
                Some(description)
            },
        });
    }
    if saw_item && items.is_empty() {
        return Err(invalid());
    }
    // Stable sorting preserves feed order for tied or absent dates.
    items.sort_by_cached_key(|v| {
        std::cmp::Reverse(
            v.published_at
                .as_ref()
                .and_then(|date| chrono::DateTime::parse_from_rfc3339(date).ok())
                .map(|date| date.timestamp()),
        )
    });
    let mut ids = HashSet::new();
    let mut urls = HashSet::new();
    items.retain(|v| {
        if ids.contains(&v.id) || urls.contains(&v.url) {
            return false;
        }
        ids.insert(v.id.clone());
        urls.insert(v.url.clone());
        true
    });
    items.truncate(MAX_ITEMS);
    Ok(items)
}

fn load_cache(path: &Path) -> Result<Option<Cache>, NewsError> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(error("cache", "Cannot read the news cache.")),
    };
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| error("cache", "Cannot read the news cache."))?;
    let invalid = || {
        error(
            "cache",
            "News cache is corrupt or has an unsupported version. Refresh to replace it.",
        )
    };
    if bytes.len() > MAX_BYTES {
        return Err(invalid());
    }
    let cache: Cache = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    let mut ids = HashSet::new();
    let mut urls = HashSet::new();
    if cache.version != 1
        || cache.last_success_ms < 0
        || cache.items.len() > MAX_ITEMS
        || cache.items.iter().any(|item| {
            item.id.is_empty()
                || item.id.chars().count() > 2048
                || !ids.insert(&item.id)
                || !urls.insert(&item.url)
                || safe_url(&item.url).as_deref() != Some(item.url.as_str())
                || item.title.is_empty()
                || !valid_cached_text(&item.title, 512)
                || item
                    .description
                    .as_ref()
                    .is_some_and(|v| !valid_cached_text(v, 4000))
                || item
                    .published_at
                    .as_ref()
                    .is_some_and(|v| chrono::DateTime::parse_from_rfc3339(v).is_err())
        })
    {
        return Err(invalid());
    }
    Ok(Some(cache))
}

fn valid_cached_text(value: &str, limit: usize) -> bool {
    // Cache fields already contain plain text; parsing them as HTML again would
    // corrupt literal angle brackets decoded from HTML entities in the feed.
    value.chars().count() <= limit && !value.chars().any(char::is_control)
}

fn prepare_cache(path: &Path, cache: &Cache) -> Result<tempfile::NamedTempFile, NewsError> {
    let failed = || {
        error(
            "cache",
            "Cannot save the news cache. Previous cache was preserved.",
        )
    };
    let mut temp = tempfile::NamedTempFile::new_in(path.parent().unwrap()).map_err(|_| failed())?;
    serde_json::to_writer(&mut temp, cache).map_err(|_| failed())?;
    temp.flush().map_err(|_| failed())?;
    temp.as_file().sync_all().map_err(|_| failed())?;
    Ok(temp)
}

fn replace_cache(path: &Path, temp: tempfile::NamedTempFile) -> Result<(), NewsError> {
    // tempfile uses MoveFileExW(REPLACE_EXISTING) on Windows; never remove the old file first.
    temp.persist(path).map_err(|_| {
        error(
            "cache",
            "Cannot save the news cache. Previous cache was preserved.",
        )
    })?;
    Ok(())
}

#[cfg(test)]
fn persist_cache(path: &Path, cache: &Cache, fail_before_replace: bool) -> Result<(), NewsError> {
    let temp = prepare_cache(path, cache)?;
    if fail_before_replace {
        return Err(error("cache", "Injected failure before atomic replace."));
    }
    replace_cache(path, temp)
}

#[cfg(test)]
mod tests;
