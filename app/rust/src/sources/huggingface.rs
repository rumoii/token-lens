//! Hugging Face sources: trending models, trending Spaces, and daily papers (specs/news.md).
//!
//! Each source parses one Hugging Face public API response: a JSON array of entries. Entries
//! missing `id` or a title are skipped; when every entry is skipped the response is a `ParseError`.
//! The client owns requests, plain-text normalisation and de-duplication.

use super::{Category, ParseError, Popularity, PopularityKind, RawItem, Source, SourceInfo};

const MODELS_URL: &str = "https://huggingface.co/api/models?sort=trendingScore&limit=30";
const SPACES_URL: &str = "https://huggingface.co/api/spaces?sort=trendingScore&limit=30";
const PAPERS_URL: &str = "https://huggingface.co/api/daily_papers?limit=30";

/// The three Hugging Face registry entries (`hf-models`, `hf-spaces`, `hf-papers`), in order.
pub fn sources() -> Vec<Box<dyn Source>> {
    vec![Box::new(Models), Box::new(Spaces), Box::new(Papers)]
}

struct Models;

struct Spaces;

struct Papers;

fn entries(body: &[u8]) -> Result<Vec<serde_json::Value>, ParseError> {
    serde_json::from_slice(body)
        .map_err(|_| ParseError("Hugging Face response is not a JSON array.".to_string()))
}

fn text(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(serde_json::Value::as_str)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// Source dates arrive as ISO 8601 with `Z`; unusable values become `None` rather than guesses.
fn date(value: Option<&serde_json::Value>) -> Option<String> {
    let raw = value?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(raw).ok().map(|v| {
        v.with_timezone(&chrono::Utc)
            .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true)
    })
}

fn popularity(value: Option<&serde_json::Value>, kind: PopularityKind) -> Option<Popularity> {
    value
        .and_then(serde_json::Value::as_i64)
        .map(|value| Popularity { kind, value })
}

fn no_valid_entries() -> ParseError {
    ParseError("Hugging Face response has no valid entries.".to_string())
}

fn done(entries: &[serde_json::Value], items: Vec<RawItem>) -> Result<Vec<RawItem>, ParseError> {
    if items.is_empty() && !entries.is_empty() {
        return Err(no_valid_entries());
    }
    Ok(items)
}

impl Source for Models {
    fn text_is_html(&self) -> bool {
        false
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "hf-models".to_string(),
            name: "Hugging Face 模型".to_string(),
            category: Category::Community,
            home_url: "https://huggingface.co/models".to_string(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        MODELS_URL.to_string()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let entries = entries(body)?;
        let mut items = Vec::new();
        for entry in &entries {
            let Some(id) = text(entry.get("id")) else {
                continue;
            };
            let url = format!("https://huggingface.co/{id}");
            items.push(RawItem {
                native_id: id.clone(),
                title: id,
                url,
                published_at: date(entry.get("createdAt")),
                description: text(entry.get("pipeline_tag")),
                popularity: popularity(entry.get("likes"), PopularityKind::Likes),
            });
        }
        done(&entries, items)
    }
}

impl Source for Spaces {
    fn text_is_html(&self) -> bool {
        false
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "hf-spaces".to_string(),
            name: "Hugging Face Spaces".to_string(),
            category: Category::Community,
            home_url: "https://huggingface.co/spaces".to_string(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        SPACES_URL.to_string()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let entries = entries(body)?;
        let mut items = Vec::new();
        for entry in &entries {
            let Some(id) = text(entry.get("id")) else {
                continue;
            };
            let card = entry.get("cardData");
            let title = text(card.and_then(|card| card.get("title"))).unwrap_or_else(|| id.clone());
            items.push(RawItem {
                native_id: id.clone(),
                title,
                url: format!("https://huggingface.co/spaces/{id}"),
                published_at: date(entry.get("createdAt")),
                description: text(card.and_then(|card| card.get("short_description"))),
                popularity: popularity(entry.get("likes"), PopularityKind::Likes),
            });
        }
        done(&entries, items)
    }
}

impl Source for Papers {
    fn text_is_html(&self) -> bool {
        false
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "hf-papers".to_string(),
            name: "Hugging Face 论文".to_string(),
            category: Category::Community,
            home_url: "https://huggingface.co/papers".to_string(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        PAPERS_URL.to_string()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let entries = entries(body)?;
        let mut items = Vec::new();
        for entry in &entries {
            let Some(paper) = entry.get("paper") else {
                continue;
            };
            let Some(id) = text(paper.get("id")) else {
                continue;
            };
            let Some(title) = text(paper.get("title")) else {
                continue;
            };
            // Both the wrapper and `paper` carry `publishedAt`; the wrapper is the entry date.
            let published_at =
                date(entry.get("publishedAt")).or_else(|| date(paper.get("publishedAt")));
            items.push(RawItem {
                native_id: id.clone(),
                title,
                url: format!("https://huggingface.co/papers/{id}"),
                published_at,
                description: text(paper.get("summary")),
                popularity: popularity(paper.get("upvotes"), PopularityKind::Upvotes),
            });
        }
        done(&entries, items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODELS_BODY: &[u8] = include_bytes!("fixtures/huggingface/models.json");
    const SPACES_BODY: &[u8] = include_bytes!("fixtures/huggingface/spaces.json");
    const PAPERS_BODY: &[u8] = include_bytes!("fixtures/huggingface/papers.json");

    #[test]
    fn sources_are_the_three_huggingface_entries_in_order() {
        let sources = sources();
        let ids: Vec<String> = sources.iter().map(|source| source.info().id).collect();
        assert_eq!(ids, ["hf-models", "hf-spaces", "hf-papers"]);
        for source in &sources {
            assert_eq!(source.info().category, Category::Community);
            assert_eq!(source.accepts(), &["application/json"]);
        }
    }

    #[test]
    fn models_parse_fixture() {
        let items = Models.parse(MODELS_BODY).unwrap();
        assert_eq!(items.len(), 10);
        assert_eq!(
            items[0],
            RawItem {
                native_id: "moonshotai/Kimi-K3.1-Pro".to_string(),
                title: "moonshotai/Kimi-K3.1-Pro".to_string(),
                url: "https://huggingface.co/moonshotai/Kimi-K3.1-Pro".to_string(),
                published_at: Some("2026-11-02T04:13:51Z".to_string()),
                description: Some("image-text-to-text".to_string()),
                popularity: Some(Popularity {
                    kind: PopularityKind::Likes,
                    value: 937,
                }),
            }
        );
    }

    #[test]
    fn models_empty_array_is_an_empty_list() {
        assert_eq!(Models.parse(b"[]").unwrap(), Vec::<RawItem>::new());
    }

    #[test]
    fn models_root_object_is_a_parse_error() {
        assert!(Models.parse(br#"{"id": "org/name"}"#).is_err());
    }

    #[test]
    fn models_skip_entries_without_id() {
        let items = Models
            .parse(
                br#"[{"likes": 1}, {"id": ""}, {"id": "org/a", "createdAt": "2026-11-02T04:13:51.000Z"}]"#,
            )
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].native_id, "org/a");
    }

    #[test]
    fn models_with_only_invalid_entries_is_a_parse_error() {
        assert!(Models.parse(br#"[{"likes": 1}, {"id": ""}]"#).is_err());
    }

    #[test]
    fn models_missing_or_unusable_date_stays_none() {
        let items = Models
            .parse(br#"[{"id": "org/a"}, {"id": "org/b", "createdAt": "yesterday"}]"#)
            .unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].published_at, None);
        assert_eq!(items[1].published_at, None);
    }

    #[test]
    fn spaces_parse_fixture() {
        let items = Spaces.parse(SPACES_BODY).unwrap();
        assert_eq!(items.len(), 10);
        assert_eq!(
            items[0],
            RawItem {
                native_id: "a-test-user-in-the-wrold/qwen-image-21-uncensored".to_string(),
                // The list API omits cardData, so the title falls back to the Space id.
                title: "a-test-user-in-the-wrold/qwen-image-21-uncensored".to_string(),
                url: "https://huggingface.co/spaces/a-test-user-in-the-wrold/qwen-image-21-uncensored"
                    .to_string(),
                published_at: Some("2026-10-11T14:32:05Z".to_string()),
                description: None,
                popularity: Some(Popularity {
                    kind: PopularityKind::Likes,
                    value: 288,
                }),
            }
        );
    }

    #[test]
    fn spaces_use_card_data_title_and_short_description_when_present() {
        let items = Spaces
            .parse(
                br#"[{"id": "org/a", "cardData": {"title": "A Space", "short_description": "Does things."}}]"#,
            )
            .unwrap();
        assert_eq!(items[0].title, "A Space");
        assert_eq!(items[0].description.as_deref(), Some("Does things."));
    }

    #[test]
    fn spaces_empty_array_is_an_empty_list() {
        assert_eq!(Spaces.parse(b"[]").unwrap(), Vec::<RawItem>::new());
    }

    #[test]
    fn spaces_root_object_is_a_parse_error() {
        assert!(Spaces.parse(br#"{"spaces": []}"#).is_err());
    }

    #[test]
    fn spaces_skip_entries_without_id() {
        let items = Spaces
            .parse(
                br#"[{"cardData": {"title": "No id"}}, {"id": "org/a", "createdAt": "2026-10-11T14:32:05.000Z"}]"#,
            )
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].native_id, "org/a");
    }

    #[test]
    fn spaces_with_only_invalid_entries_is_a_parse_error() {
        assert!(Spaces.parse(br#"[{"likes": 3}, {"id": ""}]"#).is_err());
    }

    #[test]
    fn spaces_missing_date_stays_none() {
        let items = Spaces.parse(br#"[{"id": "org/a"}]"#).unwrap();
        assert_eq!(items[0].published_at, None);
    }

    #[test]
    fn papers_parse_fixture() {
        let items = Papers.parse(PAPERS_BODY).unwrap();
        assert_eq!(items.len(), 10);
        assert_eq!(
            items[0],
            RawItem {
                native_id: "2611.06425".to_string(),
                title: "D3D: Decoupled Diffusion Drafting for Asynchronous Speculative Decoding"
                    .to_string(),
                url: "https://huggingface.co/papers/2611.06425".to_string(),
                published_at: Some("2026-11-03T19:00:00Z".to_string()),
                description: Some(
                    "Target-conditioned diffusion drafters predict candidate tokens in parallel, yet each new block must wait for updated target-model hidden states. This forces drafting and verification to run sequentially, limiting speedup even though each block is generated in one pass. We introduce D3D, a standalone diffusion drafter that removes this inter-round dependency. D3D combines blockwise denoising with auxiliary autoregressive supervision to achieve long accepted prefixes without target hidden states. This independence lets D3D draft successor blocks during verification in one packed pass, enabling asynchronous speculative decoding. We progressively prune layers according to their effect on acceptance length to reduce the cost of packed drafting. Removing five of 36 layers retains over 99\\% of mean acceptance length across three benchmarks with Qwen3-8B as the target. Across seven benchmarks, D3D averages 5.00times and 5.71times decoding speedup with Qwen3-8B and Qwen3-32B targets, compared with 4.03times and 3.67times for DFlash. On GSM8K with Qwen3-32B, speedup reaches 7.48times. Code is publicly available at https://github.com/fudan-generative-vision/D3D."
                        .to_string(),
                ),
                popularity: Some(Popularity {
                    kind: PopularityKind::Upvotes,
                    value: 5,
                }),
            }
        );
    }

    #[test]
    fn papers_empty_array_is_an_empty_list() {
        assert_eq!(Papers.parse(b"[]").unwrap(), Vec::<RawItem>::new());
    }

    #[test]
    fn papers_root_object_is_a_parse_error() {
        assert!(Papers.parse(br#"{"papers": []}"#).is_err());
    }

    #[test]
    fn papers_skip_entries_without_id_or_title() {
        let items = Papers
            .parse(
                br#"[{"publishedAt": "2026-11-03T19:00:00.000Z"}, {"paper": {"title": "No id"}}, {"paper": {"id": "2611.00001"}}, {"paper": {"id": "2611.00002", "title": "Kept"}}]"#,
            )
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].native_id, "2611.00002");
        assert_eq!(items[0].title, "Kept");
    }

    #[test]
    fn papers_with_only_invalid_entries_is_a_parse_error() {
        assert!(Papers
            .parse(br#"[{"paper": {"title": "No id"}}, {"paper": {}}]"#)
            .is_err());
    }

    #[test]
    fn papers_missing_date_stays_none() {
        let items = Papers
            .parse(br#"[{"paper": {"id": "2611.00001", "title": "No date"}}]"#)
            .unwrap();
        assert_eq!(items[0].published_at, None);
    }

    #[test]
    fn papers_use_wrapper_published_at_first() {
        let items = Papers
            .parse(
                br#"[{"publishedAt": "2026-11-03T19:00:00.000Z", "paper": {"id": "2611.00001", "title": "T", "publishedAt": "2026-11-04T00:00:00.000Z"}}]"#,
            )
            .unwrap();
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-11-03T19:00:00Z")
        );
    }

    #[test]
    fn papers_fall_back_to_paper_published_at() {
        let items = Papers
            .parse(
                br#"[{"paper": {"id": "2611.00001", "title": "T", "publishedAt": "2026-11-04T00:00:00.000Z"}}]"#,
            )
            .unwrap();
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-11-04T00:00:00Z")
        );
    }
}
