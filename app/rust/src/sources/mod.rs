//! News source contract (specs/news.md, "D2 多来源契约").
//!
//! Each module implements `Source` for one or more registry entries. Sources are pure: they build a
//! URL and parse a response body. The client owns requests, limits, plain-text normalisation, URL
//! validation, ids, de-duplication, caching and state.

// The client wires these modules in at D2 integration; until then nothing calls them.
#![allow(dead_code)]

pub mod deepseek;
pub mod github;
pub mod hackernews;
pub mod huggingface;
pub mod rss;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    Official,
    Tools,
    Community,
    Chinese,
}

impl Category {
    pub fn as_str(self) -> &'static str {
        match self {
            Category::Official => "official",
            Category::Tools => "tools",
            Category::Community => "community",
            Category::Chinese => "chinese",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceInfo {
    /// Stable registry id, such as `openai` or `gh-release:openai/codex`.
    pub id: String,
    pub name: String,
    pub category: Category,
    pub home_url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PopularityKind {
    Points,
    Stars,
    Likes,
    Upvotes,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Popularity {
    pub kind: PopularityKind,
    pub value: i64,
}

/// One entry as the source reports it. The client turns title and description into plain text and
/// rejects entries whose URL is not HTTP(S).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawItem {
    /// Unique within the source: guid, release id, or a stable link.
    pub native_id: String,
    pub title: String,
    pub url: String,
    /// RFC 3339 in UTC, or `None` when the source gives no usable date.
    pub published_at: Option<String>,
    pub description: Option<String>,
    pub popularity: Option<Popularity>,
}

/// The body could not be read as this source's format. An empty `Ok` list means the source has no
/// entries; a changed structure, missing required fields, or only invalid entries is an error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError(pub String);

pub trait Source: Send + Sync {
    fn info(&self) -> SourceInfo;

    /// The single URL fetched on refresh. `now_ms` is UTC epoch milliseconds, for sources whose
    /// query covers a time window.
    fn url(&self, now_ms: i64) -> String;

    /// Accepted Content-Type prefixes, such as `application/json`. Any other type fails before
    /// `parse` runs.
    fn accepts(&self) -> &'static [&'static str];

    /// Parses an HTTP 200 body of at most 4 MiB. No I/O and no clock.
    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError>;
}
