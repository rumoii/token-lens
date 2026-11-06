//! News source contract (specs/news.md, "D2 多来源契约").
//!
//! Each module implements `Source` for one or more registry entries. Sources are pure: they build a
//! URL and parse a response body. The client owns requests, limits, plain-text normalisation, URL
//! validation, ids, de-duplication, caching and state.

pub mod aibase;
pub mod anthropic_api;
pub mod deepseek;
pub mod github;
pub mod hackernews;
pub mod huggingface;
pub mod openai_api;
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

/// What an entry asks of a developer (specs/news.md, "D2.5"). `General` when nothing decides it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Release,
    Api,
    Deprecation,
    Pricing,
    Model,
    General,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ItemKind::Release => "release",
            ItemKind::Api => "api",
            ItemKind::Deprecation => "deprecation",
            ItemKind::Pricing => "pricing",
            ItemKind::Model => "model",
            ItemKind::General => "general",
        }
    }
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
    /// Set only from explicit source structure, such as a changelog entry's label. Never guessed
    /// from free text here; the client applies the contract's keyword rules.
    pub kind: Option<ItemKind>,
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

    /// Maximum response body size. Sources may declare a documented exception.
    fn max_body_bytes(&self) -> usize {
        4 * 1024 * 1024
    }

    /// Whether titles and descriptions contain HTML. Plain-text sources must opt out of parsing.
    fn text_is_html(&self) -> bool {
        true
    }

    /// Kind for entries that neither carry a `kind` nor match a keyword rule.
    fn default_kind(&self) -> ItemKind {
        ItemKind::General
    }

    /// Parses an HTTP 200 body within max_body_bytes(). No I/O and no clock.
    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError>;
}

/// Ordered registry shared by refresh state, URL de-duplication and the desktop UI.
pub fn registry() -> Vec<Box<dyn Source>> {
    let mut feeds = rss::feeds();
    let qbitai = feeds.pop().expect("RSS registry includes QbitAI");
    feeds.push(deepseek::news());
    feeds.push(Box::new(anthropic_api::AnthropicApi));
    feeds.push(Box::new(openai_api::OpenAiApi));
    feeds.extend(github::releases());
    feeds.push(github::new_repos());
    feeds.extend(huggingface::sources());
    feeds.push(hackernews::ai());
    feeds.push(qbitai);
    feeds.push(aibase::daily());
    feeds
}

#[cfg(test)]
mod tests {
    #[test]
    fn registry_defaults_follow_source_contract() {
        for source in super::registry() {
            let expected = if source.info().id.starts_with("gh-release:") {
                super::ItemKind::Release
            } else if matches!(source.info().id.as_str(), "anthropic-api" | "openai-api") {
                super::ItemKind::Api
            } else {
                super::ItemKind::General
            };
            assert_eq!(source.default_kind(), expected, "{}", source.info().id);
        }
    }

    #[test]
    fn registry_contains_all_nineteen_sources_in_contract_order() {
        let ids: Vec<_> = super::registry().iter().map(|s| s.info().id).collect();
        assert_eq!(
            ids,
            [
                "openai",
                "deepmind",
                "google-ai",
                "deepseek",
                "anthropic-api",
                "openai-api",
                "gh-release:anthropics/claude-code",
                "gh-release:openai/codex",
                "gh-release:google-gemini/gemini-cli",
                "gh-release:anomalyco/opencode",
                "gh-release:earendil-works/pi",
                "gh-release:ollama/ollama",
                "github-new",
                "hf-models",
                "hf-spaces",
                "hf-papers",
                "hn-ai",
                "qbitai",
                "aibase"
            ]
        );
    }
}
