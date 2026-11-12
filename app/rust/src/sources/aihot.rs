//! AIHOT RSS summaries with links to their original publishers.
use scraper::{Html, Selector};
use std::sync::LazyLock;

use super::{rss, Category, ItemKind, ParseError, RawItem, Source, SourceInfo};
use crate::api::news::{element_text, safe_url};

static PARAGRAPH: LazyLock<Selector> = LazyLock::new(|| Selector::parse("p").unwrap());
static LINK: LazyLock<Selector> = LazyLock::new(|| Selector::parse("a[href]").unwrap());

pub struct Aihot;

impl Source for Aihot {
    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "aihot".into(),
            name: "AIHOT 精选".into(),
            category: Category::Chinese,
            home_url: "https://aihot.news/".into(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        "https://aihot.news/feed.xml".into()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/rss+xml", "application/xml", "text/xml"]
    }

    fn ai_summary(&self) -> bool {
        true
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let mut items = rss::parse(body)?;
        let invalid = || ParseError("Response is not an AIHOT RSS feed.".into());
        let text = std::str::from_utf8(body).map_err(|_| invalid())?;
        let doc = roxmltree::Document::parse(text).map_err(|_| invalid())?;
        if doc.root_element().tag_name().name() != "rss" {
            return Err(invalid());
        }
        let channel = doc
            .root_element()
            .children()
            .find(|n| n.has_tag_name("channel"))
            .ok_or_else(invalid)?;
        // Match RSS's stable identity, including its link fallback for a missing guid.
        let entries: Vec<_> = channel
            .children()
            .filter(|n| n.has_tag_name("item"))
            .collect();
        for item in &mut items {
            let entry = entries
                .iter()
                .find(|entry| {
                    let guid = rss::text(**entry, "guid");
                    let identity = if guid.is_empty() {
                        rss::text(**entry, "link")
                    } else {
                        guid
                    };
                    identity == item.native_id
                })
                .ok_or_else(invalid)?;
            let author = rss::text(*entry, "author");
            item.origin = author
                .split_once('(')
                .and_then(|(_, rest)| rest.rsplit_once(')').map(|(origin, _)| origin.to_owned()));
            item.kind = (rss::text(*entry, "category") == "AI 模型").then_some(ItemKind::Model);
            if let Some(description) = &item.description {
                let html = Html::parse_fragment(description);
                if let Some(original) = html
                    .select(&LINK)
                    .find(|link| element_text(*link) == "阅读原文")
                {
                    if let Some(url) = original.value().attr("href").and_then(safe_url) {
                        item.url = url;
                    }
                }
                item.description = if let Some(first) = html.select(&PARAGRAPH).next() {
                    Some(first.html())
                } else {
                    // Remove attribution segments before the engine performs HTML text normalisation.
                    let mut fallback = html;
                    let links: Vec<_> = fallback
                        .select(&LINK)
                        .filter(|link| element_text(*link) == "阅读原文")
                        .map(|link| link.id())
                        .collect();
                    for link in links {
                        fallback.tree.get_mut(link).unwrap().detach();
                    }
                    let text = element_text(fallback.root_element());
                    let text = text
                        .split("via AIHOT")
                        .next()
                        .unwrap_or("")
                        .trim_end_matches(|c: char| c.is_whitespace() || c == '🔗')
                        .to_owned();
                    // Escape text so the engine does not decode entities or literal angle brackets twice.
                    Some(
                        text.replace('&', "&amp;")
                            .replace('<', "&lt;")
                            .replace('>', "&gt;"),
                    )
                };
            }
        }
        Ok(items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_original_falls_back_to_item_link() {
        let item = Aihot
            .parse(include_bytes!("fixtures/aihot/no-original.xml"))
            .unwrap()
            .remove(0);
        assert_eq!(item.url, "https://aihot.news/items/one");
    }

    #[test]
    fn unsafe_original_falls_back_to_item_link() {
        for body in [
            include_bytes!("fixtures/aihot/unsafe-original.xml").as_slice(),
            include_bytes!("fixtures/aihot/credential-original.xml").as_slice(),
        ] {
            assert_eq!(
                Aihot.parse(body).unwrap()[0].url,
                "https://aihot.news/items/one"
            );
        }
    }

    #[test]
    fn missing_author_has_no_origin() {
        assert_eq!(
            Aihot
                .parse(include_bytes!("fixtures/aihot/no-author.xml"))
                .unwrap()[0]
                .origin,
            None
        );
        let body = include_str!("fixtures/aihot/no-author.xml").replace(
            "</item>",
            "<author>Publisher without parentheses</author></item>",
        );
        assert_eq!(Aihot.parse(body.as_bytes()).unwrap()[0].origin, None);
    }

    #[test]
    fn only_exact_model_category_is_structural_model_kind() {
        assert_eq!(
            Aihot
                .parse(include_bytes!("fixtures/aihot/model.xml"))
                .unwrap()[0]
                .kind,
            Some(ItemKind::Model)
        );
        assert_eq!(
            Aihot
                .parse(include_bytes!("fixtures/aihot/near-model.xml"))
                .unwrap()[0]
                .kind,
            None
        );
    }

    #[test]
    fn missing_date_stays_unknown() {
        assert_eq!(
            Aihot
                .parse(include_bytes!("fixtures/aihot/no-date.xml"))
                .unwrap()[0]
                .published_at,
            None
        );
    }

    #[test]
    fn empty_channel_is_success() {
        assert!(Aihot
            .parse(include_bytes!("fixtures/aihot/empty.xml"))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn non_rss_body_is_parse_error() {
        assert!(matches!(
            Aihot.parse(include_bytes!("fixtures/aihot/invalid.xml")),
            Err(ParseError(_))
        ));
    }

    #[test]
    fn description_without_paragraphs_drops_attribution() {
        let item = Aihot
            .parse(include_bytes!("fixtures/aihot/no-paragraphs.xml"))
            .unwrap()
            .remove(0);
        assert_eq!(item.url, "https://example.com/original");
        assert_eq!(
            crate::api::news::plain_text(item.description.as_deref().unwrap(), 4000),
            "Summary text."
        );
        assert_eq!(item.origin.as_deref(), Some("Publisher：News"));
    }
}
