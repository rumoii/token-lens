//! OpenAI API changelog. Feature/Update/Fix/Announcement labels remain `None`. A secondary soft
//! badge other than a `v1/...` endpoint is the page's model label and maps to `Model`; an explicit
//! `Model: ...` label does too. Deprecation/retirement/shutdown labels map to `Deprecation` and win
//! over model labels. No kind is inferred from entry prose.

use std::sync::LazyLock;

use chrono::{Datelike, NaiveDate, SecondsFormat};
use scraper::{ElementRef, Html, Selector};

use super::{Category, ItemKind, ParseError, RawItem, Source, SourceInfo};

const PAGE_URL: &str = "https://developers.openai.com/api/docs/changelog";

static DIV: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse("div").expect("valid OpenAI container selector"));
static ENTRY: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse("div.mt-5").expect("valid OpenAI entry selector"));
static DATE: LazyLock<Selector> = LazyLock::new(|| {
    Selector::parse("div[data-variant=\"outline\"]").expect("valid OpenAI date selector")
});
static LABEL: LazyLock<Selector> = LazyLock::new(|| {
    Selector::parse("div[data-variant=\"soft\"]").expect("valid OpenAI label selector")
});

pub struct OpenAiApi;

impl Source for OpenAiApi {
    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "openai-api".to_owned(),
            name: "OpenAI API".to_owned(),
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
        parse_changelog(body)
    }
}

fn parse_changelog(body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
    let invalid = || ParseError("Response is not an OpenAI API changelog page.".to_owned());
    let html = std::str::from_utf8(body).map_err(|_| invalid())?;
    let document = Html::parse_document(html);
    let page = document
        .select(&DIV)
        .find(|element| has_class_marker(*element, "_ChangelogPage_"))
        .ok_or_else(invalid)?;
    let entries: Vec<_> = page.select(&ENTRY).collect();
    let mut items = Vec::new();

    for entry in entries.iter().copied() {
        let Some(month) = entry_month(entry) else {
            continue;
        };
        let Some(day) = entry.select(&DATE).next().and_then(|date| {
            let text = normalize(&date.text().collect::<String>());
            NaiveDate::parse_from_str(&format!("{text} 2000"), "%b %e %Y").ok()
        }) else {
            continue;
        };
        let Some(date) = NaiveDate::from_ymd_opt(month.year(), month.month(), day.day()) else {
            continue;
        };
        let Some(content) = entry
            .select(&DIV)
            .find(|element| has_class_marker(*element, "_ChangelogMarkdown_"))
        else {
            continue;
        };
        let text = crate::api::news::element_text(content);
        if text.is_empty() {
            continue;
        }
        items.push(RawItem {
            origin: None,
            native_id: format!(
                "{}#{:016x}",
                date.format("%Y-%m-%d"),
                fnv1a(text.as_bytes())
            ),
            title: first_sentence(&text)
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;"),
            url: PAGE_URL.to_owned(),
            published_at: Some(
                date.and_hms_opt(0, 0, 0)
                    .expect("midnight is a valid time")
                    .and_utc()
                    .to_rfc3339_opts(SecondsFormat::Secs, true),
            ),
            description: Some(content.inner_html()),
            popularity: None,
            kind: entry_kind(entry),
        });
    }

    if !entries.is_empty() && items.is_empty() {
        Err(invalid())
    } else {
        Ok(items)
    }
}

fn has_class_marker(element: ElementRef<'_>, marker: &str) -> bool {
    element
        .value()
        .attr("class")
        .unwrap_or_default()
        .contains(marker)
}

fn entry_month(entry: ElementRef<'_>) -> Option<NaiveDate> {
    let month = entry.parent().and_then(ElementRef::wrap)?;
    let heading = month
        .children()
        .filter_map(ElementRef::wrap)
        .find(|child| {
            child.value().name() == "h3"
                && child
                    .value()
                    .attr("class")
                    .unwrap_or_default()
                    .contains("_ChangelogSectionTitle_")
        })?;
    let text = normalize(&heading.text().collect::<String>());
    NaiveDate::parse_from_str(&format!("{text} 1"), "%B, %Y %e").ok()
}

fn entry_kind(entry: ElementRef<'_>) -> Option<ItemKind> {
    let mut deprecation = false;
    let mut model = false;
    for label in entry.select(&LABEL) {
        let text = normalize(&label.text().collect::<String>());
        let lower = text.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "deprecation"
                | "deprecated"
                | "retirement"
                | "retired"
                | "shutdown"
                | "sunset"
                | "end of life"
        ) {
            deprecation = true;
        } else if lower.starts_with("model:")
            || (label.value().attr("data-color") == Some("secondary") && !lower.starts_with("v1/"))
        {
            model = true;
        }
    }
    if deprecation {
        Some(ItemKind::Deprecation)
    } else if model {
        Some(ItemKind::Model)
    } else {
        None
    }
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

    const NORMAL_HTML: &[u8] = include_bytes!("fixtures/openai_api/normal.html");
    const EMPTY_HTML: &[u8] = include_bytes!("fixtures/openai_api/empty.html");
    const CHANGED_HTML: &[u8] = include_bytes!("fixtures/openai_api/changed.html");

    fn entry(day: &str, labels: &str, content: &str) -> String {
        format!("<div class=\"mt-5\"><div><div class=\"_Badge_test\" data-variant=\"outline\">{day}</div></div><div>{labels}<div class=\"_ChangelogMarkdown_test\">{content}</div></div></div>")
    }

    fn page(month: &str, entries: &str) -> String {
        format!("<div class=\"_ChangelogPage_test\"><div><h3 class=\"_ChangelogSectionTitle_test\">{month}</h3>{entries}</div></div>")
    }

    fn normalised_entry(content: &str) -> crate::api::news::NewsItem {
        let html = page("November, 2026", &entry("Nov 5", "", content));
        let raw = OpenAiApi
            .parse(html.as_bytes())
            .expect("entry should parse");
        crate::engine::normalise_items(
            OpenAiApi.info().id.as_str(),
            raw,
            OpenAiApi.text_is_html(),
            OpenAiApi.info().category,
            OpenAiApi.default_kind(),
            OpenAiApi.ai_summary(),
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
                OpenAiApi.info().id,
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
    fn parses_real_changelog_entries() {
        let items = OpenAiApi.parse(NORMAL_HTML).expect("fixture should parse");
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0],
            RawItem {
                origin: None,
                native_id: "2026-11-05#bdacc639970cd1f2".to_owned(),
                title: "Use GPT-6-Cyber to investigate vulnerabilities, reproduce them in an authorized test environment, and verify fixes.".to_owned(),
                url: PAGE_URL.to_owned(),
                published_at: Some("2026-11-05T00:00:00Z".to_owned()),
                description: Some("<p>Use <a class=\"_TextLink_ssta1_1\" data-underline=\"always\" href=\"/api/docs/models/gpt-6-cyber\">GPT-6-Cyber</a> to investigate vulnerabilities, reproduce them in an authorized test environment, and verify fixes. See <a class=\"_TextLink_ssta1_1\" data-underline=\"always\" href=\"/api/docs/guides/daybreak#set-up-gpt-6-cyber\">Daybreak setup</a> before sending your first request.</p>".to_owned()),
                popularity: None,
                kind: Some(ItemKind::Model),
            }
        );
        assert_eq!(items[1].native_id, "2026-11-04#7d531d664431cc49");
    }

    #[test]
    fn empty_changelog_is_ok() {
        assert!(OpenAiApi
            .parse(EMPTY_HTML)
            .expect("empty page should parse")
            .is_empty());
    }

    #[test]
    fn changed_structure_is_an_error() {
        assert!(OpenAiApi.parse(CHANGED_HTML).is_err());
    }

    #[test]
    fn missing_date_skips_only_the_undated_entry() {
        let html = page(
            "November, 2026",
            &format!(
                "{}{}",
                entry("", "", "<p>Undated.</p>"),
                entry("Nov 5", "", "<p>Dated.</p>")
            ),
        );
        let items = OpenAiApi
            .parse(html.as_bytes())
            .expect("dated entry should parse");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Dated.");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-11-05T00:00:00Z")
        );
    }

    #[test]
    fn entries_without_a_date_heading_are_an_error() {
        let html = format!(
            "<div class=\"_ChangelogPage_test\">{}</div>",
            entry("Nov 5", "", "<p>Undated by month.</p>")
        );
        assert!(OpenAiApi.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn all_invalid_entries_are_an_error() {
        let html = page("November, 2026", &entry("Nov 5", "", "<p></p>"));
        assert!(OpenAiApi.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn same_day_entries_remain_separate() {
        let html = page(
            "November, 2026",
            &format!(
                "{}{}",
                entry("Nov 5", "", "<p>First entry.</p>"),
                entry("Nov 5", "", "<p>Second entry.</p>")
            ),
        );
        let items = OpenAiApi
            .parse(html.as_bytes())
            .expect("entries should parse");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].published_at, items[1].published_at);
        assert_ne!(items[0].native_id, items[1].native_id);
    }

    #[test]
    fn ids_are_stable_and_content_sensitive() {
        let first = OpenAiApi
            .parse(NORMAL_HTML)
            .expect("first parse should work");
        let second = OpenAiApi
            .parse(NORMAL_HTML)
            .expect("second parse should work");
        assert_eq!(first[0].native_id, second[0].native_id);
        let html = page(
            "November, 2026",
            &entry("Nov 5", "", "<p>Changed entry.</p>"),
        );
        let changed = OpenAiApi
            .parse(html.as_bytes())
            .expect("changed entry should parse");
        assert_ne!(changed[0].native_id, first[0].native_id);
    }

    #[test]
    fn labels_map_to_model_or_deprecation_without_reading_prose() {
        let feature =
            "<div class=\"_Badge_test\" data-color=\"success\" data-variant=\"soft\">Feature</div>";
        let update =
            "<div class=\"_Badge_test\" data-color=\"success\" data-variant=\"soft\">Update</div>";
        let model =
            "<div class=\"_Badge_test\" data-color=\"secondary\" data-variant=\"soft\">gpt-5</div>";
        let endpoint = "<div class=\"_Badge_test\" data-color=\"secondary\" data-variant=\"soft\">v1/responses</div>";
        let deprecation = "<div class=\"_Badge_test\" data-color=\"warning\" data-variant=\"soft\">Deprecation</div>";
        let entries = [
            entry(
                "Nov 1",
                &format!("{feature}{model}"),
                "<p>Model feature.</p>",
            ),
            entry("Nov 2", update, "<p>General update.</p>"),
            entry(
                "Nov 3",
                &format!("{update}{endpoint}"),
                "<p>Endpoint update.</p>",
            ),
            entry(
                "Nov 4",
                &format!("{deprecation}{model}"),
                "<p>Model retirement.</p>",
            ),
            entry(
                "Nov 5",
                feature,
                "<p>The prose says deprecated but has no such label.</p>",
            ),
        ]
        .concat();
        let items = OpenAiApi
            .parse(page("November, 2026", &entries).as_bytes())
            .expect("labels should parse");
        let kinds: Vec<_> = items.iter().map(|item| item.kind).collect();
        assert_eq!(
            kinds,
            [
                Some(ItemKind::Model),
                None,
                None,
                Some(ItemKind::Deprecation),
                None
            ]
        );
    }

    #[test]
    fn block_boundaries_separate_sentences() {
        let html = page(
            "November, 2026",
            &entry("Nov 5", "", "<p>First sentence.</p><p>Second sentence.</p>"),
        );
        let items = OpenAiApi
            .parse(html.as_bytes())
            .expect("block entry should parse");
        assert_eq!(items[0].title, "First sentence.");
    }

    #[test]
    fn titles_use_the_first_sentence_and_are_limited_to_160_characters() {
        let long = "a".repeat(170);
        let html = page(
            "November, 2026",
            &entry("Nov 5", "", &format!("<p>{long}. Second sentence.</p>")),
        );
        let items = OpenAiApi
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
        assert_eq!(OpenAiApi.url(0), PAGE_URL);
        assert_eq!(OpenAiApi.info().id, "openai-api");
        assert_eq!(OpenAiApi.accepts(), &["text/html"]);
        assert_eq!(OpenAiApi.default_kind(), ItemKind::Api);
        assert_eq!(OpenAiApi.max_body_bytes(), 4 * 1024 * 1024);
    }
}
