//! Source module; see `super::Source` and specs/news.md.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;

use super::{Category, ParseError, Popularity, PopularityKind, RawItem, Source, SourceInfo};

const AI_KEYWORDS: &[&str] = &[
    "ai",
    "llm",
    "llms",
    "gpt",
    "claude",
    "gemini",
    "openai",
    "anthropic",
    "agent",
    "agents",
    "model",
    "models",
    "deepseek",
    "llama",
    "qwen",
    "mistral",
    "transformer",
    "inference",
    "rag",
];

struct HackerNews;

pub fn ai() -> Box<dyn Source> {
    Box::new(HackerNews)
}

impl Source for HackerNews {
    fn text_is_html(&self) -> bool {
        false
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "hn-ai".to_owned(),
            name: "Hacker News".to_owned(),
            category: Category::Community,
            home_url: "https://news.ycombinator.com".to_owned(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=100".to_owned()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let response: SearchResponse = serde_json::from_slice(body)
            .map_err(|err| ParseError(format!("invalid Hacker News response: {err}")))?;
        let had_hits = !response.hits.is_empty();
        let mut saw_valid_hit = false;
        let mut items = Vec::new();
        for hit in response.hits {
            let (Some(native_id), Some(title)) = (
                hit.object_id.filter(|id| !id.is_empty()),
                hit.title.filter(|title| !title.is_empty()),
            ) else {
                continue;
            };
            saw_valid_hit = true;
            if !is_ai_title(&title) {
                continue;
            }
            let url = hit
                .url
                .filter(|url| !url.is_empty())
                .unwrap_or_else(|| format!("https://news.ycombinator.com/item?id={native_id}"));
            items.push(RawItem {
                kind: None,
                native_id,
                title,
                url,
                published_at: parse_date(hit.created_at),
                description: None,
                popularity: hit.points.map(|value| Popularity {
                    kind: PopularityKind::Points,
                    value,
                }),
            });
        }
        if had_hits && !saw_valid_hit {
            Err(ParseError(
                "Hacker News response contained no valid entries".to_owned(),
            ))
        } else {
            Ok(items)
        }
    }
}

#[derive(Deserialize)]
struct SearchResponse {
    hits: Vec<Hit>,
}

#[derive(Deserialize)]
struct Hit {
    #[serde(rename = "objectID")]
    object_id: Option<String>,
    title: Option<String>,
    url: Option<String>,
    created_at: Option<String>,
    points: Option<i64>,
}

fn is_ai_title(title: &str) -> bool {
    let title = title.to_lowercase();
    AI_KEYWORDS.iter().any(|keyword| {
        title.match_indices(keyword).any(|(start, _)| {
            let end = start + keyword.len();
            let before = title[..start].chars().next_back();
            let after = title[end..].chars().next();
            before.is_none_or(|c| !is_word_char(c)) && after.is_none_or(|c| !is_word_char(c))
        })
    })
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn parse_date(value: Option<String>) -> Option<String> {
    value
        .and_then(|value| DateTime::parse_from_rfc3339(&value).ok())
        .map(|value| {
            value
                .with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::AutoSi, true)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sources::{Popularity, PopularityKind};

    #[test]
    fn source_info_and_request_match_contract() {
        let source = ai();
        let info = source.info();
        assert_eq!(info.id, "hn-ai");
        assert_eq!(info.name, "Hacker News");
        assert_eq!(info.category, Category::Community);
        assert_eq!(info.home_url, "https://news.ycombinator.com");
        assert_eq!(
            source.url(0),
            "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=100"
        );
        assert_eq!(source.accepts(), &["application/json"]);
    }

    #[test]
    fn parser_filters_titles_and_maps_fields() {
        let items = ai()
            .parse(include_bytes!("fixtures/hackernews/front-page.json"))
            .unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0],
            RawItem {
                kind: None,
                native_id: "50385272".to_owned(),
                title: "Claude Code sends your email address to websites".to_owned(),
                url: "https://github.com/anthropics/claude-code/issues/107757".to_owned(),
                published_at: Some("2026-11-05T22:17:15Z".to_owned()),
                description: None,
                popularity: Some(Popularity {
                    kind: PopularityKind::Points,
                    value: 582,
                }),
            }
        );
        assert_eq!(
            items[1].url,
            "https://news.ycombinator.com/item?id=50380000"
        );
        assert_eq!(
            items[1].published_at.as_deref(),
            Some("2026-11-05T23:00:00Z")
        );
        assert!(items
            .iter()
            .all(|item| item.native_id != "50380001" && item.native_id != "50380002"));
    }

    #[test]
    fn parser_accepts_empty_hits() {
        let items = ai()
            .parse(include_bytes!("fixtures/hackernews/front-page-empty.json"))
            .unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn parser_allows_missing_date() {
        let items = ai()
            .parse(include_bytes!(
                "fixtures/hackernews/front-page-missing-date.json"
            ))
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].published_at, None);
    }

    #[test]
    fn parser_rejects_changed_structure() {
        assert!(ai()
            .parse(include_bytes!(
                "fixtures/hackernews/front-page-structure-changed.json"
            ))
            .is_err());
    }

    #[test]
    fn parser_rejects_when_all_relevant_entries_invalid() {
        assert!(ai()
            .parse(include_bytes!(
                "fixtures/hackernews/front-page-invalid.json"
            ))
            .is_err());
    }

    #[test]
    fn parser_returns_empty_when_front_page_is_unrelated() {
        let items = ai()
            .parse(include_bytes!(
                "fixtures/hackernews/front-page-unrelated.json"
            ))
            .unwrap();
        assert!(items.is_empty());
    }
}
