//! DeepSeek official news, read from the "News" section of <https://api-docs.deepseek.com/>.
//!
//! Every news page renders the full news list in the documentation sidebar, so one request to any
//! news page returns all titles, links and dates.

use std::sync::LazyLock;

use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};
use reqwest::Url;
use scraper::{ElementRef, Html, Selector};

use super::{Category, ParseError, RawItem, Source, SourceInfo};

/// The News entry in the site navigation; its sidebar lists every news page.
const LIST_URL: &str = "https://api-docs.deepseek.com/news/news261017/";
/// Relative sidebar links resolve from the news section, not from the article path.
const BASE_URL: &str = "https://api-docs.deepseek.com/news/";
const SITE_HOST: &str = "api-docs.deepseek.com";
const NEWS_PATH_PREFIX: &str = "/news/";

/// Sidebar menu that holds the news list on every news page.
const NEWS_LIST_SELECTOR: &str = "nav[aria-label=\"Docs sidebar\"] ul.theme-doc-sidebar-menu";
/// One news entry: the link inside a sidebar list item.
const NEWS_ITEM_SELECTOR: &str = "li a[href]";
/// Any link in the sidebar; used to tell an empty list from a changed structure.
const NEWS_ANY_LINK_SELECTOR: &str = "a[href]";
/// Date element inside a list item, when the page shows the date separately from the title.
const NEWS_DATE_SELECTOR: &str = "time[datetime]";

static NEWS_LIST: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(NEWS_LIST_SELECTOR).expect("valid news list selector"));
static NEWS_ITEM: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(NEWS_ITEM_SELECTOR).expect("valid news item selector"));
static NEWS_ANY_LINK: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(NEWS_ANY_LINK_SELECTOR).expect("valid link selector"));
static NEWS_DATE: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(NEWS_DATE_SELECTOR).expect("valid date selector"));

pub struct News;

pub fn news() -> Box<dyn Source> {
    Box::new(News)
}

impl Source for News {
    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "deepseek".to_owned(),
            name: "DeepSeek".to_owned(),
            category: Category::Official,
            home_url: LIST_URL.to_owned(),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        LIST_URL.to_owned()
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["text/html"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        parse_news(body)
    }
}

fn parse_news(body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
    let invalid = || ParseError("Response is not a DeepSeek news page.".to_owned());
    let html = std::str::from_utf8(body).map_err(|_| invalid())?;
    let document = Html::parse_document(html);
    let list = document.select(&NEWS_LIST).next().ok_or_else(invalid)?;
    let anchors: Vec<_> = list.select(&NEWS_ITEM).collect();
    // Links that no longer sit in list items mean the sidebar was rebuilt, not emptied.
    if anchors.is_empty() && list.select(&NEWS_ANY_LINK).next().is_some() {
        return Err(invalid());
    }
    let mut items = Vec::new();
    for anchor in anchors {
        let Some(url) = absolute_url(anchor.value().attr("href").unwrap_or_default()) else {
            continue;
        };
        let native_id = url.path().to_owned();
        if native_id.len() > 2048 {
            continue;
        }
        let title = anchor.text().collect::<String>().trim().to_owned();
        if title.is_empty() {
            continue;
        }
        let published_at = list_date(&anchor)
            .or_else(|| date_in_text(&title).map(format_date))
            .or_else(|| date_in_path(&native_id).map(format_date));
        items.push(RawItem {
            kind: None,
            native_id,
            title,
            url: url.to_string(),
            published_at,
            description: None,
            popularity: None,
        });
    }
    if !items.is_empty() || list.select(&NEWS_ANY_LINK).next().is_none() {
        Ok(items)
    } else {
        Err(invalid())
    }
}

/// Resolves a sidebar link against the news page and keeps it on the documentation host.
fn absolute_url(href: &str) -> Option<Url> {
    let href = href.trim();
    if href.is_empty() {
        return None;
    }
    let base = Url::parse(BASE_URL).ok()?;
    let url = base.join(href).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str() != Some(SITE_HOST)
        || !url.username().is_empty()
        || url.password().is_some()
        || !url.path().starts_with(NEWS_PATH_PREFIX)
    {
        return None;
    }
    Some(url)
}

/// Reads the date element next to the link, when the list shows one.
fn list_date(anchor: &ElementRef<'_>) -> Option<String> {
    let scope = anchor
        .parent()
        .and_then(ElementRef::wrap)
        .filter(|parent| parent.value().name() == "li")
        .unwrap_or(*anchor);
    let value = scope.select(&NEWS_DATE).next()?.value().attr("datetime")?;
    if let Ok(date) = DateTime::parse_from_rfc3339(value) {
        return Some(
            date.with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::Secs, true),
        );
    }
    NaiveDate::parse_from_str(value.trim(), "%Y-%m-%d")
        .ok()
        .map(format_date)
}

/// Finds a `YYYY/MM/DD` date in the link text, such as `DeepSeek-V3.2 Release 2025/09/29`.
fn date_in_text(text: &str) -> Option<NaiveDate> {
    let bytes = text.as_bytes();
    for start in 0..bytes.len() {
        if bytes[start].is_ascii_digit() && (start == 0 || !bytes[start - 1].is_ascii_digit()) {
            if let Some(date) = slash_date_at(bytes, start) {
                return Some(date);
            }
        }
    }
    None
}

fn slash_date_at(bytes: &[u8], start: usize) -> Option<NaiveDate> {
    let year_end = start + 4;
    if year_end + 4 > bytes.len()
        || !bytes[start..year_end].iter().all(u8::is_ascii_digit)
        || bytes[year_end] != b'/'
    {
        return None;
    }
    let mut cursor = year_end + 1;
    let month_start = cursor;
    while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
        cursor += 1;
    }
    let month_len = cursor - month_start;
    if !(1..=2).contains(&month_len) || bytes.get(cursor) != Some(&b'/') {
        return None;
    }
    cursor += 1;
    let day_start = cursor;
    while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
        cursor += 1;
    }
    let day_len = cursor - day_start;
    if !(1..=2).contains(&day_len) {
        return None;
    }
    let year = std::str::from_utf8(&bytes[start..year_end])
        .ok()?
        .parse()
        .ok()?;
    let month = std::str::from_utf8(&bytes[month_start..month_start + month_len])
        .ok()?
        .parse()
        .ok()?;
    let day = std::str::from_utf8(&bytes[day_start..cursor])
        .ok()?
        .parse()
        .ok()?;
    NaiveDate::from_ymd_opt(year, month, day)
}

/// Reads the `YYMMDD` date from the page path, such as `/news/news250929`.
fn date_in_path(path: &str) -> Option<NaiveDate> {
    let segment = path.trim_end_matches('/').rsplit('/').next()?;
    let digits = segment.strip_prefix("news")?;
    if digits.len() != 6 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let year = 2000 + digits[0..2].parse::<i32>().ok()?;
    let month = digits[2..4].parse().ok()?;
    let day = digits[4..6].parse().ok()?;
    NaiveDate::from_ymd_opt(year, month, day)
}

fn format_date(date: NaiveDate) -> String {
    date.and_hms_opt(0, 0, 0)
        .expect("midnight is a valid time")
        .and_utc()
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NEWS_HTML: &[u8] = include_bytes!("fixtures/deepseek/news.html");
    const CHANGED_HTML: &[u8] = include_bytes!("fixtures/deepseek/changed.html");
    const EMPTY_HTML: &[u8] = include_bytes!("fixtures/deepseek/empty.html");

    fn page(list: &str) -> String {
        format!(
            "<!doctype html><html><body><nav aria-label=\"Docs sidebar\"><ul class=\"theme-doc-sidebar-menu\">{list}</ul></nav></body></html>"
        )
    }

    #[test]
    fn parses_the_news_list() {
        let items = News.parse(NEWS_HTML).expect("fixture should parse");
        assert_eq!(items.len(), 19);
        assert_eq!(
            items[0],
            RawItem {
                kind: None,
                native_id: "/news/news261017".to_owned(),
                title: "DeepSeek-V4.1-Flash-1017 Release 2026/10/17".to_owned(),
                url: "https://api-docs.deepseek.com/news/news261017".to_owned(),
                published_at: Some("2026-10-17T00:00:00Z".to_owned()),
                description: None,
                popularity: None,
            }
        );
        assert_eq!(
            items.last().unwrap(),
            &RawItem {
                kind: None,
                native_id: "/news/news0725".to_owned(),
                title: "New API Features 2024/07/25".to_owned(),
                url: "https://api-docs.deepseek.com/news/news0725".to_owned(),
                published_at: Some("2024-07-25T00:00:00Z".to_owned()),
                description: None,
                popularity: None,
            }
        );
    }

    #[test]
    fn changed_structure_is_an_error() {
        assert!(News.parse(CHANGED_HTML).is_err());
    }

    #[test]
    fn empty_list_is_ok() {
        let items = News.parse(EMPTY_HTML).expect("empty list should parse");
        assert!(items.is_empty());
    }

    #[test]
    fn non_html_body_is_an_error() {
        assert!(News.parse(br#"{"items":[]}"#).is_err());
    }

    #[test]
    fn entries_without_links_or_titles_are_an_error() {
        let html = page("<li><a href=\"/news/news250929\"></a></li>");
        assert!(News.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn relative_links_become_absolute_urls() {
        let html = page(
            "<li><a href=\"news250929\">DeepSeek-V3.2-Exp Release 2025/09/29</a></li>\
             <li><a href=\"/news/news250120\">DeepSeek-R1 Release 2025/01/20</a></li>",
        );
        let items = News
            .parse(html.as_bytes())
            .expect("relative links should parse");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].native_id, "/news/news250929");
        assert_eq!(
            items[0].url,
            "https://api-docs.deepseek.com/news/news250929"
        );
        assert_eq!(items[1].native_id, "/news/news250120");
        assert_eq!(
            items[1].url,
            "https://api-docs.deepseek.com/news/news250120"
        );
    }

    #[test]
    fn title_dates_are_used_when_present() {
        let html = page(
            "<li><a href=\"/news/news250929\">DeepSeek-V3.2-Exp Release 2025/09/29</a></li>\
             <li><a href=\"/news/news0802\">Context Caching is Available</a></li>",
        );
        let items = News.parse(html.as_bytes()).expect("titles should parse");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2025-09-29T00:00:00Z")
        );
        // The path date `0802` has no year, and the title has none either.
        assert_eq!(items[1].published_at, None);
    }

    #[test]
    fn path_dates_are_used_when_the_title_has_none() {
        let html = page("<li><a href=\"/news/news250929\">Compressed path date</a></li>");
        let items = News.parse(html.as_bytes()).expect("path date should parse");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2025-09-29T00:00:00Z")
        );
    }

    #[test]
    fn list_dates_win_over_title_dates() {
        let html = page(
            "<li><a href=\"/news/news250929\">DeepSeek-V3.2-Exp Release 2025/09/29</a>\
             <time datetime=\"2025-10-01T08:30:00+08:00\"></time></li>",
        );
        let items = News.parse(html.as_bytes()).expect("list date should parse");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2025-10-01T00:30:00Z")
        );
    }
}
