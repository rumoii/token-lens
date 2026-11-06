//! Anthropic Claude Platform release notes. The page has no entry-level kind labels, so `kind`
//! remains unset and the client applies its keyword rules before this source's `api` default.

use std::sync::LazyLock;

use chrono::{NaiveDate, SecondsFormat};
use reqwest::Url;
use scraper::{ElementRef, Html, Selector};

use super::{Category, ItemKind, ParseError, RawItem, Source, SourceInfo};

const PAGE_URL: &str = "https://platform.claude.com/docs/en/release-notes/overview";

static PROSE: LazyLock<Selector> = LazyLock::new(|| {
    Selector::parse("article#content-container > div[data-cds=\"Prose\"]")
        .expect("valid Anthropic release notes selector")
});

pub struct AnthropicApi;

impl Source for AnthropicApi {
    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "anthropic-api".to_owned(),
            name: "Anthropic API".to_owned(),
            category: Category::Official,
            home_url: PAGE_URL.to_owned(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        PAGE_URL.to_owned()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["text/html"]
    }

    fn default_kind(&self) -> ItemKind {
        ItemKind::Api
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        parse_release_notes(body)
    }
}

fn parse_release_notes(body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
    let invalid = || ParseError("Response is not an Anthropic API release notes page.".to_owned());
    let html = std::str::from_utf8(body).map_err(|_| invalid())?;
    let document = Html::parse_document(html);
    let prose = document.select(&PROSE).next().ok_or_else(invalid)?;
    let mut items = Vec::new();
    let mut saw_entry = false;
    let mut current_date = None;

    for child in prose.children().filter_map(ElementRef::wrap) {
        match child.value().name() {
            "h3" => {
                current_date = parse_date(&child.text().collect::<String>()).map(|date| {
                    let anchor = child.value().attr("id").filter(|id| !id.is_empty());
                    (date, anchor)
                });
            }
            "p" => {
                saw_entry = true;
                if let Some((date, anchor)) = current_date {
                    if let Some(item) = parse_entry(child, date, anchor) {
                        items.push(item);
                    }
                }
            }
            "ul" | "ol" => {
                for entry in child
                    .children()
                    .filter_map(ElementRef::wrap)
                    .filter(|entry| entry.value().name() == "li")
                {
                    saw_entry = true;
                    if let Some((date, anchor)) = current_date {
                        if let Some(item) = parse_entry(entry, date, anchor) {
                            items.push(item);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    if saw_entry && items.is_empty() {
        Err(invalid())
    } else {
        Ok(items)
    }
}

fn parse_entry(entry: ElementRef<'_>, date: NaiveDate, anchor: Option<&str>) -> Option<RawItem> {
    let text = crate::api::news::element_text(entry);
    if text.is_empty() {
        return None;
    }
    let mut url = Url::parse(PAGE_URL).expect("the Anthropic release notes URL is valid");
    url.set_fragment(anchor);
    Some(RawItem {
        native_id: format!(
            "{}#{:016x}",
            date.format("%Y-%m-%d"),
            fnv1a(text.as_bytes())
        ),
        title: first_sentence(&text)
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;"),
        url: url.into(),
        published_at: Some(
            date.and_hms_opt(0, 0, 0)
                .expect("midnight is a valid time")
                .and_utc()
                .to_rfc3339_opts(SecondsFormat::Secs, true),
        ),
        description: Some(entry.inner_html()),
        popularity: None,
        kind: None,
    })
}

fn parse_date(text: &str) -> Option<NaiveDate> {
    let text = normalize(text);
    let parts: Vec<_> = text.split_whitespace().collect();
    parts.windows(3).find_map(|parts| {
        let month = parts[0];
        let day = parts[1].trim_end_matches(',');
        let year = parts[2];
        let day = ["st", "nd", "rd", "th"]
            .iter()
            .find_map(|suffix| day.strip_suffix(suffix))
            .unwrap_or(day);
        NaiveDate::parse_from_str(&format!("{month} {day} {year}"), "%B %e %Y").ok()
    })
}

fn normalize(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn first_sentence(text: &str) -> String {
    let end = text
        .char_indices()
        .find_map(|(index, character)| {
            let next = index + character.len_utf8();
            (matches!(character, '。' | '！' | '？')
                || (matches!(character, '.' | '!' | '?')
                    && text[next..]
                        .chars()
                        .next()
                        .map(char::is_whitespace)
                        .unwrap_or(true)))
            .then_some(next)
        })
        .unwrap_or(text.len());
    text[..end].chars().take(160).collect()
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const NORMAL_HTML: &[u8] = include_bytes!("fixtures/anthropic_api/normal.html");
    const EMPTY_HTML: &[u8] = include_bytes!("fixtures/anthropic_api/empty.html");
    const CHANGED_HTML: &[u8] = include_bytes!("fixtures/anthropic_api/changed.html");

    fn page(content: &str) -> String {
        format!(
            "<article id=\"content-container\"><div data-cds=\"Prose\">{content}</div></article>"
        )
    }

    fn normalised_entry(content: &str) -> crate::api::news::NewsItem {
        let html = page(&format!(
            "<h3>November 5, 2026</h3><ul><li>{content}</li></ul>"
        ));
        let raw = AnthropicApi
            .parse(html.as_bytes())
            .expect("entry should parse");
        crate::engine::normalise_items(
            AnthropicApi.info().id.as_str(),
            raw,
            AnthropicApi.text_is_html(),
            AnthropicApi.info().category,
            AnthropicApi.default_kind(),
        )
        .expect("entry should normalise")
        .remove(0)
    }

    #[test]
    fn d25_r4_literal_angle_brackets_survive_normalisation() {
        let item =
            normalised_entry("<p>Use &lt;thinking&gt; &amp; Vec&lt;String&gt;. Details.</p>");
        assert_eq!(item.title, "Use <thinking> & Vec<String>.");
        assert_eq!(
            item.description.as_deref(),
            Some("Use <thinking> & Vec<String>. Details.")
        );
    }

    #[test]
    fn d25_r4_literal_deprecated_tag_is_classified_after_normalisation() {
        let item = normalised_entry("<p>The &lt;deprecated&gt; parameter is removed.</p>");
        assert_eq!(item.title, "The <deprecated> parameter is removed.");
        assert_eq!(item.kind, "deprecation");
    }

    #[test]
    fn d25_r4_inline_nodes_join_without_spaces_and_blocks_stay_separate() {
        let content =
            "<p>We’<!-- -->ve updated <a>Opus 5.5</a>.</p><div>Second<br>paragraph.</div>";
        let item = normalised_entry(content);
        let expected = "We’ve updated Opus 5.5. Second paragraph.";
        assert_eq!(item.title, "We’ve updated Opus 5.5.");
        assert_eq!(item.description.as_deref(), Some(expected));
        assert_eq!(
            item.id,
            format!(
                "{}:2026-11-05#{:016x}",
                AnthropicApi.info().id,
                fnv1a(expected.as_bytes())
            )
        );
    }

    #[test]
    fn d25_r4_chinese_sentences_split_without_whitespace_and_versions_stay_whole() {
        for (content, expected) in [
            ("第一句。第二句。", "第一句。"),
            ("第一句！第二句。", "第一句！"),
            ("第一句？第二句。", "第一句？"),
            ("Version 2.0 ships. More details.", "Version 2.0 ships."),
            ("Ready! More details.", "Ready!"),
            ("Ready? More details.", "Ready?"),
            ("Keep x!y and a?b. More details.", "Keep x!y and a?b."),
        ] {
            assert_eq!(normalised_entry(content).title, expected, "{content}");
        }
    }

    #[test]
    fn parses_real_release_notes() {
        let items = AnthropicApi
            .parse(NORMAL_HTML)
            .expect("fixture should parse");
        assert_eq!(items.len(), 3);
        assert_eq!(
            items[0],
            RawItem {
                native_id: "2026-11-05#d6376c932f4ece27".to_owned(),
                title: "You can now set up an IP allowlist for your organization in the Claude Console, in beta.".to_owned(),
                url: "https://platform.claude.com/docs/en/release-notes/overview#november-5-2026".to_owned(),
                published_at: Some("2026-11-05T00:00:00Z".to_owned()),
                description: Some("You can now set up an IP allowlist for your organization in the Claude Console, in beta. Requests to covered services from addresses not on your list are refused, which limits where a leaked API key can be used. Add IPv4 and IPv6 addresses or CIDR ranges, up to 1,000 per organization. See <a href=\"/docs/en/manage-claude/ip-allowlist\">IP allowlisting</a> for what’s covered and how to set it up.".to_owned()),
                popularity: None,
                kind: None,
            }
        );
        assert_eq!(items[1].published_at, items[0].published_at);
        assert_ne!(items[1].native_id, items[0].native_id);
        assert_eq!(items[1].native_id, "2026-11-05#191f773b6cb5c124");
    }

    #[test]
    fn empty_release_notes_are_ok() {
        assert!(AnthropicApi
            .parse(EMPTY_HTML)
            .expect("empty page should parse")
            .is_empty());
    }

    #[test]
    fn changed_structure_is_an_error() {
        assert!(AnthropicApi.parse(CHANGED_HTML).is_err());
    }

    #[test]
    fn missing_date_skips_only_the_undated_entry() {
        let html = page("<p>Undated introduction.</p><h3 id=\"january-2-2026\">January 2, 2026</h3><ul><li>Dated entry.</li></ul>");
        let items = AnthropicApi
            .parse(html.as_bytes())
            .expect("dated entry should parse");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Dated entry.");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-01-02T00:00:00Z")
        );
    }

    #[test]
    fn entries_without_any_date_heading_are_an_error() {
        let html = page("<p>Undated entry.</p><ul><li>Another undated entry.</li></ul>");
        assert!(AnthropicApi.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn all_invalid_entries_are_an_error() {
        let html = page("<h3 id=\"january-2-2026\">January 2, 2026</h3><ul><li> </li></ul>");
        assert!(AnthropicApi.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn ids_are_stable_and_content_sensitive() {
        let first = AnthropicApi
            .parse(NORMAL_HTML)
            .expect("first parse should work");
        let second = AnthropicApi
            .parse(NORMAL_HTML)
            .expect("second parse should work");
        assert_eq!(first[0].native_id, second[0].native_id);
        let html =
            page("<h3 id=\"january-2-2026\">January 2, 2026</h3><ul><li>Changed entry.</li></ul>");
        let changed = AnthropicApi
            .parse(html.as_bytes())
            .expect("changed entry should parse");
        assert_ne!(changed[0].native_id, first[0].native_id);
    }

    #[test]
    fn d25_r4_date_headings_use_all_text_and_ignore_anchor_markers() {
        for heading in [
            "\n  <a href=\"#x\">#</a> November 5, 2026\n",
            "\n November <em>5th,</em> 2026 <a href=\"#x\">#</a>\n",
        ] {
            let html = page(&format!("<h3 id=\"x\">{heading}</h3><p>Dated entry.</p>"));
            let items = AnthropicApi
                .parse(html.as_bytes())
                .expect("date heading should parse");
            assert_eq!(
                items[0].published_at.as_deref(),
                Some("2026-11-05T00:00:00Z")
            );
            assert!(items[0].url.ends_with("#x"));
        }
    }

    #[test]
    fn ordinal_dates_and_paragraph_entries_are_supported() {
        let html = page("<h3 id=\"december-17th-2024\">December 17th, 2024</h3><p>First paragraph.</p><p>Second paragraph!</p>");
        let items = AnthropicApi
            .parse(html.as_bytes())
            .expect("ordinal date should parse");
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2024-12-17T00:00:00Z")
        );
        assert_eq!(items[0].title, "First paragraph.");
        assert_eq!(items[1].title, "Second paragraph!");
    }

    #[test]
    fn block_boundaries_separate_sentences() {
        let html = page("<h3>January 2, 2026</h3><ul><li><p>First sentence.</p><p>Second sentence.</p></li></ul>");
        let items = AnthropicApi
            .parse(html.as_bytes())
            .expect("block entry should parse");
        assert_eq!(items[0].title, "First sentence.");
    }

    #[test]
    fn titles_use_the_first_sentence_and_are_limited_to_160_characters() {
        let long = "a".repeat(170);
        let html = page(&format!(
            "<h3>January 2, 2026</h3><p>{long}. Second sentence.</p>"
        ));
        let items = AnthropicApi
            .parse(html.as_bytes())
            .expect("long entry should parse");
        assert_eq!(items[0].title.chars().count(), 160);
        assert!(items[0]
            .description
            .as_deref()
            .unwrap()
            .contains("Second sentence."));
    }

    #[test]
    fn source_metadata_uses_the_final_200_url_and_api_default() {
        assert_eq!(AnthropicApi.url(0), PAGE_URL);
        assert_eq!(AnthropicApi.info().id, "anthropic-api");
        assert_eq!(AnthropicApi.accepts(), &["text/html"]);
        assert_eq!(AnthropicApi.default_kind(), ItemKind::Api);
        assert_eq!(AnthropicApi.max_body_bytes(), 4 * 1024 * 1024);
    }
}
