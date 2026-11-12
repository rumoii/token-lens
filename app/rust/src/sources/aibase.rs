//! AIbase daily reports, read from the server-rendered list at
//! <https://www.aibase.com/zh/daily>.
//!
//! The list labels every issue with a date and clock time, such as
//! `2026年11月5号 16:39`, but the page declares no timezone. Only the calendar date is used: it
//! maps to UTC midnight, following the date-only source convention. The clock time is ignored
//! rather than guessed. The list itself shows no summary text, so descriptions stay empty.

use std::sync::LazyLock;

use chrono::{NaiveDate, SecondsFormat};
use reqwest::Url;
use scraper::{ElementRef, Html, Selector};

use super::{Category, ParseError, RawItem, Source, SourceInfo};

const LIST_URL: &str = "https://www.aibase.com/zh/daily";
const SITE_HOST: &str = "www.aibase.com";
const NEWS_HOST: &str = "news.aibase.com";
const DAILY_PATH_PREFIX: &str = "/daily/";
const LOCALIZED_DAILY_PATH_PREFIX: &str = "/zh/daily/";

/// The inner page wrapper that holds every daily issue. The outer page has a single `<main>`; the
/// list adds a second one. Losing that second `<main>` means the page was rebuilt.
const LIST_SELECTOR: &str = "main main";
/// Every link inside the list wrapper. Issue links are kept by the daily-path check below; the
/// featured issue's `/news/` topic links are filtered out, and an empty list is told apart from a
/// changed one by whether any link remains.
const LINK_SELECTOR: &str = "a[href]";
/// Issue title inside its link.
const TITLE_SELECTOR: &str = "h3";

static LIST: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(LIST_SELECTOR).expect("valid list selector"));
static LINK: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(LINK_SELECTOR).expect("valid link selector"));
static TITLE: LazyLock<Selector> =
    LazyLock::new(|| Selector::parse(TITLE_SELECTOR).expect("valid title selector"));

pub struct Daily;

pub fn daily() -> Box<dyn Source> {
    Box::new(Daily)
}

impl Source for Daily {
    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "aibase".to_owned(),
            name: "AIbase 日报".to_owned(),
            category: Category::Chinese,
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
        parse_daily(body)
    }
}

fn parse_daily(body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
    let invalid = || ParseError("Response is not an AIbase daily list page.".to_owned());
    let html = std::str::from_utf8(body).map_err(|_| invalid())?;
    let document = Html::parse_document(html);
    let list = document.select(&LIST).next().ok_or_else(invalid)?;
    let mut items = Vec::new();
    for anchor in list.select(&LINK) {
        let Some(url) = anchor.value().attr("href").and_then(absolute_url) else {
            continue;
        };
        let native_id = native_id(&url);
        if native_id.len() > 2048 {
            continue;
        }
        let title = anchor
            .select(&TITLE)
            .next()
            .map(|title| title.text().collect::<String>().trim().to_owned())
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let published_at = issue_date(&anchor).map(format_date);
        items.push(RawItem {
            origin: None,
            kind: None,
            native_id,
            title,
            url: url.to_string(),
            published_at,
            description: None,
            popularity: None,
        });
    }
    if !items.is_empty() || list.select(&LINK).next().is_none() {
        Ok(items)
    } else {
        Err(invalid())
    }
}

/// Resolves an issue link against the list page and keeps it on an AIbase daily path.
fn absolute_url(href: &str) -> Option<Url> {
    let href = href.trim();
    if href.is_empty() {
        return None;
    }
    let base = Url::parse(LIST_URL).ok()?;
    let url = base.join(href).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || !matches!(url.host_str(), Some(SITE_HOST) | Some(NEWS_HOST))
        || !url.username().is_empty()
        || url.password().is_some()
        || !is_daily_path(url.path())
    {
        return None;
    }
    Some(url)
}

fn is_daily_path(path: &str) -> bool {
    path.starts_with(DAILY_PATH_PREFIX) || path.starts_with(LOCALIZED_DAILY_PATH_PREFIX)
}

/// Uses the stable numeric id at the end of an issue link, or the whole link when there is none.
fn native_id(url: &Url) -> String {
    let path = url.path().trim_end_matches('/');
    let last = path.rsplit('/').next().unwrap_or_default();
    if !last.is_empty() && last.bytes().all(|byte| byte.is_ascii_digit()) {
        return last.to_owned();
    }
    url.to_string()
}

/// Reads the issue's dated label from its own direct child, so dates inside a headline are never
/// used. The title block and image box are skipped.
fn issue_date(anchor: &ElementRef<'_>) -> Option<NaiveDate> {
    anchor
        .children()
        .filter_map(ElementRef::wrap)
        .filter(|child| child.value().name() != "h3" && child.select(&TITLE).next().is_none())
        .find_map(|child| leading_date(&child.text().collect::<String>()))
}

/// Reads a leading `YYYY年M月D日` or `YYYY年M月D号` label.
fn leading_date(text: &str) -> Option<NaiveDate> {
    let mut chars = text.trim_start().chars().peekable();
    let (year, year_len) = take_digits(&mut chars, 4);
    if year_len != 4 || chars.next() != Some('年') {
        return None;
    }
    let (month, month_len) = take_digits(&mut chars, 2);
    if month_len == 0 || chars.next() != Some('月') {
        return None;
    }
    let (day, day_len) = take_digits(&mut chars, 2);
    if day_len == 0 || !matches!(chars.next(), Some('日' | '号')) {
        return None;
    }
    NaiveDate::from_ymd_opt(year as i32, month, day)
}

fn take_digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>, max: usize) -> (u32, usize) {
    let mut value = 0;
    let mut count = 0;
    while count < max {
        let Some(digit) = chars.peek().and_then(|ch| ch.to_digit(10)) else {
            break;
        };
        chars.next();
        value = value * 10 + digit;
        count += 1;
    }
    (value, count)
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

    const NORMAL_HTML: &[u8] = include_bytes!("fixtures/aibase/normal.html");
    const EMPTY_HTML: &[u8] = include_bytes!("fixtures/aibase/empty.html");
    const MISSING_DATE_HTML: &[u8] = include_bytes!("fixtures/aibase/missing-date.html");
    const CHANGED_HTML: &[u8] = include_bytes!("fixtures/aibase/changed.html");
    const ALL_INVALID_HTML: &[u8] = include_bytes!("fixtures/aibase/all-invalid.html");

    fn page(items: &str) -> String {
        format!(
            "<!doctype html><html><body><main><main class=\"flex flex-col mx-auto w-full\">{items}</main></main></body></html>"
        )
    }

    #[test]
    fn parses_the_daily_list() {
        let items = Daily.parse(NORMAL_HTML).expect("fixture should parse");
        assert_eq!(items.len(), 10);
        assert_eq!(
            items[0],
            RawItem {
                origin: None,
                kind: None,
                native_id: "32121".to_owned(),
                title: "AI日报：iOS 27.3 beta正式接入千问；豆包工作首次接入第三方模型；雷军晒小米机器人做家务视频".to_owned(),
                url: "https://www.aibase.com/daily/32121".to_owned(),
                published_at: Some("2026-11-05T00:00:00Z".to_owned()),
                description: None,
                popularity: None,
            }
        );
        assert_eq!(items[9].native_id, "31845");
        assert_eq!(
            items[9].published_at.as_deref(),
            Some("2026-10-23T00:00:00Z")
        );
    }

    #[test]
    fn empty_list_is_ok() {
        let items = Daily.parse(EMPTY_HTML).expect("empty list should parse");
        assert!(items.is_empty());
    }

    #[test]
    fn an_issue_without_a_date_stays_undated() {
        let items = Daily
            .parse(MISSING_DATE_HTML)
            .expect("missing date should parse");
        assert_eq!(items.len(), 10);
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-11-05T00:00:00Z")
        );
        assert_eq!(items[1].native_id, "32090");
        assert_eq!(items[1].published_at, None);
    }

    #[test]
    fn changed_structure_is_an_error() {
        assert!(Daily.parse(CHANGED_HTML).is_err());
    }

    #[test]
    fn entries_without_titles_are_an_error() {
        assert!(Daily.parse(ALL_INVALID_HTML).is_err());
    }

    #[test]
    fn non_html_body_is_an_error() {
        assert!(Daily.parse(br#"{"items":[]}"#).is_err());
    }

    #[test]
    fn entries_without_links_or_titles_are_an_error() {
        let html = page(r#"<a href="/daily/32121"></a>"#);
        assert!(Daily.parse(html.as_bytes()).is_err());
    }

    #[test]
    fn relative_links_become_absolute_urls() {
        let html = page(
            r#"<a href="/daily/32121"><div>2026年11月5号 16:39</div><h3>Root relative</h3></a>
               <a href="https://www.aibase.com/daily/32122"><div>2026年11月4号 17:19</div><h3>Absolute</h3></a>
               <a href="daily/32123"><div>2026年11月3号 16:44</div><h3>Path relative</h3></a>"#,
        );
        let items = Daily
            .parse(html.as_bytes())
            .expect("relative links should parse");
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].url, "https://www.aibase.com/daily/32121");
        assert_eq!(items[1].url, "https://www.aibase.com/daily/32122");
        assert_eq!(items[2].url, "https://www.aibase.com/zh/daily/32123");
    }

    #[test]
    fn d25_r4_date_only_issues_use_utc_midnight() {
        let html = page(
            r#"<a href="/daily/1"><div>2026年11月5号 16:39</div><h3>Number day</h3></a>
               <a href="/daily/2"><div>2026年1月1日</div><h3>Year rollover</h3></a>
               <a href="/daily/3"><div>2024年2月29日 08:00</div><h3>Leap day</h3></a>
               <a href="/daily/4"><div>2026年13月1日</div><h3>Bad date</h3></a>"#,
        );
        let items = Daily.parse(html.as_bytes()).expect("dates should parse");
        assert_eq!(
            items[0].published_at.as_deref(),
            Some("2026-11-05T00:00:00Z")
        );
        assert_eq!(
            items[1].published_at.as_deref(),
            Some("2026-01-01T00:00:00Z")
        );
        assert_eq!(
            items[2].published_at.as_deref(),
            Some("2024-02-29T00:00:00Z")
        );
        assert_eq!(items[3].published_at, None);
    }

    #[test]
    fn dates_in_titles_are_not_used() {
        let html = page(r#"<a href="/daily/1"><h3>2026年11月5号 的日报</h3></a>"#);
        let items = Daily.parse(html.as_bytes()).expect("title should parse");
        assert_eq!(items[0].published_at, None);
    }
}
