//! RSS 2.0 and Atom sources. Transport and text normalisation belong to the engine.
use super::{Category, ParseError, RawItem, Source, SourceInfo};

pub struct RssSource {
    info: SourceInfo,
    endpoint: String,
}

impl RssSource {
    pub(crate) fn new(
        id: &str,
        name: &str,
        category: Category,
        home: &str,
        endpoint: &str,
    ) -> Self {
        Self {
            info: SourceInfo {
                id: id.into(),
                name: name.into(),
                category,
                home_url: home.into(),
            },
            endpoint: endpoint.into(),
        }
    }
}

pub fn feeds() -> Vec<Box<dyn Source>> {
    vec![
        Box::new(RssSource::new(
            "openai",
            "OpenAI",
            Category::Official,
            "https://openai.com/news/",
            "https://openai.com/news/rss.xml",
        )),
        Box::new(RssSource::new(
            "deepmind",
            "Google DeepMind",
            Category::Official,
            "https://deepmind.google/blog/",
            "https://deepmind.google/blog/rss.xml",
        )),
        Box::new(RssSource::new(
            "google-ai",
            "Google AI",
            Category::Official,
            "https://blog.google/innovation-and-ai/technology/ai/",
            "https://blog.google/innovation-and-ai/technology/ai/rss/",
        )),
        Box::new(RssSource::new(
            "qbitai",
            "量子位",
            Category::Chinese,
            "https://www.qbitai.com/",
            "https://www.qbitai.com/feed",
        )),
    ]
}

impl Source for RssSource {
    fn info(&self) -> SourceInfo {
        self.info.clone()
    }
    fn url(&self, _now_ms: i64) -> String {
        self.endpoint.clone()
    }
    fn accepts(&self) -> &'static [&'static str] {
        &[
            "application/rss+xml",
            "application/atom+xml",
            "application/xml",
            "text/xml",
        ]
    }
    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        parse(body)
    }
}

pub(crate) fn text(node: roxmltree::Node<'_, '_>, name: &str) -> String {
    node.children()
        .find(|n| {
            n.is_element()
                && n.tag_name().name() == name
                && n.tag_name().namespace() == node.tag_name().namespace()
        })
        .map(|n| {
            n.descendants()
                .filter(|n| n.is_text())
                .filter_map(|n| n.text())
                .collect::<String>()
        })
        .unwrap_or_default()
        .trim()
        .to_owned()
}

pub(crate) fn parse(body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
    let invalid = || ParseError("Response is not a valid RSS or Atom news feed.".into());
    let input = std::str::from_utf8(body).map_err(|_| invalid())?;
    let doc = roxmltree::Document::parse(input).map_err(|_| invalid())?;
    let root = doc.root_element();
    let atom = root.tag_name().name() == "feed"
        && root.tag_name().namespace() == Some("http://www.w3.org/2005/Atom");
    let parent = if atom {
        if text(root, "title").is_empty() {
            return Err(invalid());
        }
        root
    } else {
        if root.tag_name().name() != "rss" || root.attribute("version") != Some("2.0") {
            return Err(invalid());
        }
        let channels: Vec<_> = root
            .children()
            .filter(|n| n.is_element() && n.tag_name().name() == "channel")
            .collect();
        if channels.len() != 1 {
            return Err(invalid());
        }
        let channel = channels[0];
        if text(channel, "title").is_empty()
            || text(channel, "link").is_empty()
            || text(channel, "description").is_empty()
        {
            return Err(invalid());
        }
        channel
    };
    let mut items = Vec::new();
    let mut saw_entry = false;
    // A changed entry container must not masquerade as a successful empty feed.
    for child in parent
        .children()
        .filter(|n| n.is_element() && n.tag_name().namespace() == parent.tag_name().namespace())
    {
        let name = child.tag_name().name();
        let known = if atom {
            matches!(
                name,
                "entry"
                    | "author"
                    | "category"
                    | "contributor"
                    | "generator"
                    | "icon"
                    | "id"
                    | "link"
                    | "logo"
                    | "rights"
                    | "subtitle"
                    | "title"
                    | "updated"
            )
        } else {
            matches!(
                name,
                "item"
                    | "title"
                    | "link"
                    | "description"
                    | "language"
                    | "copyright"
                    | "managingEditor"
                    | "webMaster"
                    | "pubDate"
                    | "lastBuildDate"
                    | "category"
                    | "generator"
                    | "docs"
                    | "cloud"
                    | "ttl"
                    | "image"
                    | "rating"
                    | "textInput"
                    | "skipHours"
                    | "skipDays"
            )
        };
        if !known {
            return Err(invalid());
        }
    }
    for entry in parent
        .children()
        .filter(|n| n.is_element() && n.tag_name().name() == if atom { "entry" } else { "item" })
    {
        saw_entry = true;
        let title = text(entry, "title");
        let url = if atom {
            entry
                .children()
                .find(|n| {
                    n.is_element()
                        && n.tag_name().name() == "link"
                        && matches!(n.attribute("rel"), None | Some("alternate"))
                })
                .and_then(|n| n.attribute("href"))
                .unwrap_or("")
                .trim()
                .to_owned()
        } else {
            text(entry, "link")
        };
        if title.is_empty() || url.is_empty() {
            continue;
        }
        let identity = text(entry, if atom { "id" } else { "guid" });
        let date = if atom {
            let published = text(entry, "published");
            if published.is_empty() {
                text(entry, "updated")
            } else {
                published
            }
        } else {
            text(entry, "pubDate")
        };
        let published_at = if atom {
            chrono::DateTime::parse_from_rfc3339(&date)
        } else {
            chrono::DateTime::parse_from_rfc2822(&date)
        }
        .ok()
        .map(|d| {
            d.with_timezone(&chrono::Utc)
                .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true)
        });
        let description = text(entry, if atom { "summary" } else { "description" });
        items.push(RawItem {
            origin: None,
            kind: None,
            native_id: if identity.is_empty() {
                url.clone()
            } else {
                identity
            },
            title,
            url,
            published_at,
            description: (!description.is_empty()).then_some(description),
            popularity: None,
        });
    }
    if saw_entry && items.is_empty() {
        return Err(invalid());
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_feeds_preserve_first_item_fields() {
        let fixtures: [(&[u8], &[u8]); 4] = [
            (
                include_bytes!("fixtures/rss/openai.xml"),
                include_bytes!("fixtures/rss/openai-first.json"),
            ),
            (
                include_bytes!("fixtures/rss/deepmind.xml"),
                include_bytes!("fixtures/rss/deepmind-first.json"),
            ),
            (
                include_bytes!("fixtures/rss/google-ai.xml"),
                include_bytes!("fixtures/rss/google-ai-first.json"),
            ),
            (
                include_bytes!("fixtures/rss/qbitai.xml"),
                include_bytes!("fixtures/rss/qbitai-first.json"),
            ),
        ];
        for (source, (body, expected)) in feeds().iter().zip(fixtures) {
            let expected: serde_json::Value = serde_json::from_slice(expected).unwrap();
            let items = source.parse(body).unwrap();
            assert_eq!(items.len(), 3, "{}", source.info().id);
            let item = &items[0];
            assert_eq!(item.native_id, expected["native_id"].as_str().unwrap());
            assert_eq!(item.title, expected["title"].as_str().unwrap());
            assert_eq!(item.url, expected["url"].as_str().unwrap());
            assert_eq!(
                item.published_at.as_deref(),
                expected["published_at"].as_str()
            );
            assert_eq!(
                item.description.as_deref(),
                expected["description"].as_str()
            );
            assert_eq!(item.popularity, None);
        }
    }

    #[test]
    fn rss_and_atom_boundaries_for_each_source() {
        let formats: [[&[u8]; 5]; 2] = [
            [
                include_bytes!("fixtures/rss/rss-normal.xml"),
                include_bytes!("fixtures/rss/rss-empty.xml"),
                include_bytes!("fixtures/rss/rss-missing-date.xml"),
                include_bytes!("fixtures/rss/rss-invalid.xml"),
                include_bytes!("fixtures/rss/rss-changed.xml"),
            ],
            [
                include_bytes!("fixtures/rss/atom-normal.xml"),
                include_bytes!("fixtures/rss/atom-empty.xml"),
                include_bytes!("fixtures/rss/atom-missing-date.xml"),
                include_bytes!("fixtures/rss/atom-invalid.xml"),
                include_bytes!("fixtures/rss/atom-changed.xml"),
            ],
        ];
        for source in feeds() {
            for [normal, empty, missing_date, invalid, changed] in formats {
                let items = source.parse(normal).unwrap();
                assert_eq!(
                    items,
                    vec![RawItem {
                        origin: None,
                        kind: None,
                        native_id: "one".into(),
                        title: "One".into(),
                        url: "https://example.com/one".into(),
                        published_at: Some("2026-11-05T15:00:00Z".into()),
                        description: Some("Summary".into()),
                        popularity: None
                    }]
                );
                assert!(source.parse(empty).unwrap().is_empty());
                assert_eq!(source.parse(missing_date).unwrap()[0].published_at, None);
                assert!(source.parse(invalid).is_err());
                assert!(source.parse(changed).is_err());
            }
        }
    }

    #[test]
    fn registry_and_pure_url_building() {
        let sources = feeds();
        assert_eq!(
            sources.iter().map(|s| s.info().id).collect::<Vec<_>>(),
            ["openai", "deepmind", "google-ai", "qbitai"]
        );
        for source in sources {
            assert_eq!(source.url(0), source.url(i64::MAX));
            assert!(!source.info().name.is_empty());
            assert!(source.info().home_url.starts_with("https://"));
        }
    }
}
