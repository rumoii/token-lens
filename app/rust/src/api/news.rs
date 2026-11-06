use crate::engine::NewsEngine;
use crate::sources::{self, rss, Category, Source};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::path::Path;
#[cfg(test)]
use std::time::Duration;

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
}

#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct NewsClient {
    engine: NewsEngine,
}

impl NewsClient {
    /// Opens the cache without making source requests.
    pub fn new(data_dir: String) -> Result<NewsClient, String> {
        Ok(Self {
            engine: NewsEngine::new(Path::new(&data_dir), sources::registry())?,
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
            engine: NewsEngine::new(Path::new(&data_dir), sources)?,
        })
    }

    pub fn snapshot(&self) -> NewsSnapshot {
        self.engine.snapshot()
    }
    pub async fn refresh(&self, source_ids: Option<Vec<String>>) -> NewsSnapshot {
        self.engine.refresh(source_ids).await
    }
    pub fn set_source_enabled(&self, id: String, enabled: bool) -> NewsSnapshot {
        self.engine.set_source_enabled(&id, enabled)
    }
    pub fn cancel_refresh(&self) {
        self.engine.cancel_refresh();
    }
    pub fn shutdown(&self) {
        self.engine.shutdown();
    }

    #[cfg(test)]
    fn new_for_test(data_dir: &Path, endpoint: String, timeout: Duration) -> Result<Self, String> {
        Ok(Self {
            engine: NewsEngine::open(
                data_dir,
                vec![Box::new(rss::RssSource::new(
                    "openai",
                    "OpenAI",
                    Category::Official,
                    "https://openai.com/news/",
                    &endpoint,
                ))],
                timeout,
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
        .filter(|c| !c.is_control())
        .take(limit)
        .collect()
}

#[cfg(test)]
mod tests;
