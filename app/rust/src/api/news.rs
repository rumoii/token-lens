use crate::engine::NewsEngine;
use crate::sources::{self, rss, Category, Source};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewsError {
    pub kind: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewsItem {
    pub id: String,
    pub source_id: String,
    pub title: String,
    pub url: String,
    pub published_at: Option<String>,
    pub description: Option<String>,
    pub popularity_kind: Option<String>,
    pub popularity: Option<i64>,
    pub also_in: Vec<String>,
    pub kind: String,
    pub ai_summary: bool,
    pub origin: Option<String>,
    pub first_seen_ms: i64,
    #[serde(skip)]
    pub read: bool,
    #[serde(skip)]
    pub starred: bool,
}

#[derive(Clone, Debug)]
pub struct SourceState {
    pub id: String,
    pub name: String,
    pub category: String,
    pub home_url: String,
    pub enabled: bool,
    pub refreshing: bool,
    pub last_success_ms: Option<i64>,
    pub error: Option<NewsError>,
}

#[derive(Clone, Debug, Default)]
pub struct NewsSnapshot {
    pub sources: Vec<SourceState>,
    pub items: Vec<NewsItem>,
    pub refreshing: bool,
    pub error: Option<NewsError>,
    pub starred: Vec<NewsItem>,
    pub state_error: Option<NewsError>,
}

#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct NewsClient {
    engine: NewsEngine,
    data: std::path::PathBuf,
}

impl NewsClient {
    /// Opens the cache without making source requests.
    pub fn new(data_dir: String) -> Result<NewsClient, String> {
        Ok(Self {
            data: data_dir.clone().into(),
            engine: NewsEngine::new(
                Path::new(&data_dir),
                sources::registry(),
                chrono::Utc::now().timestamp_millis(),
            )
            .map_err(crate::startup_error::StartupCode::fallback)
            .inspect_err(|e| {
                crate::diagnostics::RuntimeLog::new(Path::new(&data_dir), None)
                    .ffi::<()>("NewsClient.new", Err(e.clone()))
                    .ok();
            })?,
        })
    }

    /// Controlled FFI test ingress. Only numeric HTTP loopback endpoints are accepted.
    /// The desktop entry point always uses `new` and the fixed public-source registry.
    pub fn new_for_local_test(
        data_dir: String,
        endpoints: Vec<String>,
    ) -> Result<NewsClient, String> {
        let mut sources: Vec<Box<dyn Source>> = Vec::new();
        for (index, endpoint) in endpoints.into_iter().enumerate() {
            let valid = safe_url(&endpoint)
                .and_then(|s| Url::parse(&s).ok())
                .is_some_and(|url| {
                    url.scheme() == "http"
                        && url
                            .host_str()
                            .and_then(|host| {
                                host.trim_matches(['[', ']'])
                                    .parse::<std::net::IpAddr>()
                                    .ok()
                            })
                            .is_some_and(|ip| ip.is_loopback())
                });
            if !valid {
                return Err("test: Only HTTP loopback endpoints are accepted.".into());
            }
            let id = format!("local-{index}");
            sources.push(Box::new(rss::RssSource::new(
                &id,
                &id,
                Category::Official,
                &endpoint,
                &endpoint,
            )));
        }
        Ok(Self {
            data: data_dir.clone().into(),
            engine: NewsEngine::new(
                Path::new(&data_dir),
                sources,
                chrono::Utc::now().timestamp_millis(),
            )
            .inspect_err(|e| {
                crate::diagnostics::RuntimeLog::new(Path::new(&data_dir), None)
                    .ffi::<()>("NewsClient.new", Err(e.clone()))
                    .ok();
            })?,
        })
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn logged_snapshot(&self, operation: &str, snapshot: NewsSnapshot) -> NewsSnapshot {
        // Rejected calls after shutdown can still carry stale per-source errors.
        if snapshot
            .error
            .as_ref()
            .is_some_and(|error| error.kind == "closed")
        {
            return snapshot;
        }
        let log = crate::diagnostics::RuntimeLog::new(&self.data, None);
        for error in snapshot.error.iter().chain(snapshot.state_error.iter()) {
            log.write("ERROR", "ffi", &format!("{operation}: {}", error.kind));
        }
        for source in &snapshot.sources {
            if let Some(error) = &source.error {
                log.write(
                    "ERROR",
                    "news",
                    &format!("{operation} source={} kind={}", source.id, error.kind),
                );
            }
        }
        snapshot
    }
    pub fn snapshot(&self) -> NewsSnapshot {
        self.logged_snapshot("snapshot", self.engine.snapshot())
    }
    pub async fn refresh(&self, source_ids: Option<Vec<String>>) -> NewsSnapshot {
        self.logged_snapshot(
            "refresh",
            self.engine
                .refresh(source_ids, chrono::Utc::now().timestamp_millis())
                .await,
        )
    }
    pub fn set_source_enabled(&self, id: String, enabled: bool) -> NewsSnapshot {
        self.logged_snapshot(
            "set_source_enabled",
            self.engine.set_source_enabled(&id, enabled),
        )
    }
    pub fn set_read(&self, ids: Vec<String>, read: bool) -> NewsSnapshot {
        self.logged_snapshot(
            "set_read",
            self.engine
                .set_read(ids, read, chrono::Utc::now().timestamp_millis()),
        )
    }
    pub fn set_starred(&self, id: String, starred: bool) -> NewsSnapshot {
        self.logged_snapshot(
            "set_starred",
            self.engine
                .set_starred(&id, starred, chrono::Utc::now().timestamp_millis()),
        )
    }
    pub fn cancel_refresh(&self) {
        self.engine.cancel_refresh();
    }
    pub fn shutdown(&self) {
        self.engine.shutdown();
        let _ = crate::diagnostics::flush_runtime_log(crate::diagnostics::LOG_FLUSH_TIMEOUT);
    }

    #[cfg(test)]
    fn new_for_test(
        data_dir: &Path,
        endpoint: String,
        timeouts: crate::engine::RequestTimeouts,
    ) -> Result<Self, String> {
        Ok(Self {
            data: data_dir.to_path_buf(),
            engine: NewsEngine::open(
                data_dir,
                vec![Box::new(rss::RssSource::new(
                    "openai",
                    "OpenAI",
                    Category::Official,
                    "https://openai.com/news/",
                    &endpoint,
                ))],
                timeouts,
                1794000000000,
            )?,
        })
    }
}

pub(crate) fn safe_url(raw: &str) -> Option<String> {
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

pub(crate) fn plain_text(raw: &str, limit: usize) -> String {
    let fragment = scraper::Html::parse_fragment(raw);
    element_text(fragment.root_element())
        .chars()
        .take(limit)
        .collect()
}

/// Inline nodes preserve adjacency; block boundaries separate words and sentences.
pub(crate) fn element_text(element: scraper::ElementRef<'_>) -> String {
    let mut value = String::new();
    let mut pending = vec![(*element, false)];
    while let Some((node, closing)) = pending.pop() {
        if closing {
            value.push(' ');
            continue;
        }
        match node.value() {
            scraper::Node::Text(text) => value.push_str(text),
            scraper::Node::Element(element) => {
                if matches!(element.name(), "script" | "style" | "noscript" | "template") {
                    continue;
                }
                if matches!(
                    element.name(),
                    "p" | "li"
                        | "div"
                        | "br"
                        | "hr"
                        | "ul"
                        | "ol"
                        | "dl"
                        | "dt"
                        | "dd"
                        | "blockquote"
                        | "pre"
                        | "section"
                        | "article"
                        | "header"
                        | "footer"
                        | "h1"
                        | "h2"
                        | "h3"
                        | "h4"
                        | "h5"
                        | "h6"
                        | "table"
                        | "tr"
                        | "td"
                        | "th"
                ) {
                    value.push(' ');
                    pending.push((node, true));
                }
                pending.extend(node.children().rev().map(|child| (child, false)));
            }
            _ => {}
        }
    }
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect()
}

#[cfg(test)]
mod tests;
