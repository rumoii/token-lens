use super::*;
use crate::engine;
impl NewsSnapshot {
    fn failure(&self) -> Option<&NewsError> {
        self.error
            .as_ref()
            .or_else(|| self.sources.iter().find_map(|s| s.error.as_ref()))
    }
}
use std::fs::OpenOptions;
const MAX_BYTES: usize = 4 * 1024 * 1024;

#[derive(Serialize)]
struct Cache {
    version: u32,
    items: Vec<NewsItem>,
    last_success_ms: i64,
}
fn persist_cache(path: &Path, cache: &Cache, fail_before_replace: bool) -> Result<(), NewsError> {
    let value = serde_json::json!({"version": cache.version, "last_success_ms": cache.last_success_ms,
        "items": cache.items.iter().map(|item| serde_json::json!({
            "id": item.id.strip_prefix("openai:").unwrap_or(&item.id), "title": item.title, "url": item.url,
            "published_at": item.published_at, "description": item.description
        })).collect::<Vec<_>>()});
    let temp = engine::prepare_cache(path, &value)?;
    if fail_before_replace {
        return Err(engine::error(
            "cache",
            "Injected failure before atomic replace.",
        ));
    }
    engine::replace_cache(path, temp)
}
fn parse_feed(bytes: &[u8]) -> Result<Vec<NewsItem>, NewsError> {
    let source = rss::feeds().remove(0);
    let raw = source
        .parse(bytes)
        .map_err(|_| engine::error("parse", "Invalid feed."))?;
    engine::normalise_items("openai", raw, source.text_is_html())
}
fn cached_items(path: &Path) -> Vec<NewsItem> {
    NewsClient::new(path.parent().unwrap().to_string_lossy().into_owned())
        .unwrap()
        .snapshot()
        .items
}

#[tokio::test]
async fn d2_success_writes_v2_cache() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let task = tokio::spawn(async move { client.refresh(None).await });
    seen.await.unwrap();
    reply.send(response("200 OK", &rss(""))).unwrap();
    assert!(task.await.unwrap().error.is_none());
    let json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("news-cache.json")).unwrap())
            .unwrap();
    assert_eq!(json["version"], 2);
    assert!(json["sources"]["openai"].is_object());
}

#[test]
fn d2_atom_and_utc_dates() {
    let atom = include_bytes!("../../sources/fixtures/rss/atom-normal.xml");
    let items = parse_feed(atom).unwrap();
    assert_eq!(
        items[0].published_at.as_deref(),
        Some("2026-11-05T15:00:00Z")
    );
}

#[test]
fn accepts_empty_rss_but_rejects_html() {
    assert!(parse_feed(b"<rss version=\"2.0\"><channel><title>News</title><link>https://openai.com/news/</link><description>News</description></channel></rss>").unwrap().is_empty());
    assert!(parse_feed(b"<html><body>Unavailable</body></html>").is_err());
}

#[test]
fn rss_boundary_rejects_all_invalid_items_but_accepts_empty_and_mixed() {
    assert!(parse_feed(rss("").as_bytes()).unwrap().is_empty());
    let invalid = "<item><title>No link</title></item><item><link>https://openai.com/missing-title</link></item>";
    assert_eq!(
        parse_feed(rss(invalid).as_bytes()).unwrap_err().kind,
        "parse"
    );
    let mixed = rss(&format!(
        "{invalid}{}",
        item("valid", "https://openai.com/valid", "Valid")
    ));
    assert_eq!(parse_feed(mixed.as_bytes()).unwrap().len(), 1);
}

async fn assert_rejected_response_preserves_cache(
    body: &str,
    content_type: Option<&str>,
    expected_kind: &str,
) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let items =
        parse_feed(rss(&item("kept", "https://openai.com/kept", "Kept")).as_bytes()).unwrap();
    persist_cache(
        &path,
        &Cache {
            version: 1,
            items: items.clone(),
            last_success_ms: 1234,
        },
        false,
    )
    .unwrap();
    let previous = std::fs::read(&path).unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    let header = content_type
        .map(|v| format!("Content-Type: {v}\r\n"))
        .unwrap_or_default();
    reply
        .send(format!(
            "HTTP/1.1 200 OK\r\n{header}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        ))
        .unwrap();
    let result = running.await.unwrap();
    assert_eq!(result.failure().unwrap().kind, expected_kind);
    assert_eq!(result.items, items);
    assert_eq!(result.sources[0].last_success_ms, Some(1234));
    assert_eq!(std::fs::read(path).unwrap(), previous);
}

#[tokio::test]
async fn rss_boundary_malformed_items_preserve_cache() {
    assert_rejected_response_preserves_cache(
        &rss("<item><title>No link</title></item>"),
        Some("application/rss+xml"),
        "parse",
    )
    .await;
}

#[tokio::test]
async fn rss_boundary_html_content_type_preserves_cache() {
    assert_rejected_response_preserves_cache(
        &rss(&item(
            "looks-valid",
            "https://openai.com/looks-valid",
            "Looks valid",
        )),
        Some("text/html; charset=UTF-8"),
        "content_type",
    )
    .await;
}

#[tokio::test]
async fn rss_boundary_accepts_xml_content_types_and_missing_header() {
    for content_type in [
        Some("application/rss+xml; charset=utf-8"),
        Some("application/xml"),
        Some("text/xml"),
        None,
    ] {
        let dir = tempfile::tempdir().unwrap();
        let (url, seen, reply) = server().await;
        let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
        let running = {
            let client = client.clone();
            tokio::spawn(async move { client.refresh(None).await })
        };
        seen.await.unwrap();
        let body = rss("");
        let header = content_type
            .map(|v| format!("Content-Type: {v}\r\n"))
            .unwrap_or_default();
        reply
            .send(format!(
                "HTTP/1.1 200 OK\r\n{header}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ))
            .unwrap();
        let result = running.await.unwrap();
        assert!(
            result.error.is_none(),
            "{content_type:?}: {:?}",
            result.error
        );
        assert!(result.items.is_empty());
        assert!(result.sources[0].last_success_ms.is_some());
    }
}

#[test]
fn load_is_offline_and_lock_is_exclusive() {
    let dir = tempfile::tempdir().unwrap();
    let client = NewsClient::new(dir.path().to_string_lossy().into_owned()).unwrap();
    assert!(client.snapshot().items.is_empty());
    assert!(!client.snapshot().refreshing);
    assert!(NewsClient::new(dir.path().to_string_lossy().into_owned()).is_err());
    client.shutdown();
    NewsClient::new(dir.path().to_string_lossy().into_owned()).unwrap();
}

fn rss(items: &str) -> String {
    format!("<rss version=\"2.0\"><channel><title>News</title><link>https://openai.com/news/</link><description>News</description>{items}</channel></rss>")
}

fn item(id: &str, url: &str, title: &str) -> String {
    format!("<item><guid>{id}</guid><title><![CDATA[{title}]]></title><link>{url}</link><description><![CDATA[<p>Hello &amp; <b>world</b></p><script>alert(1)</script>]]></description><pubDate>Tue, 03 Nov 2026 12:00:00 GMT</pubDate></item>")
}

#[test]
fn sanitizes_deduplicates_and_limits_feed() {
    let mut input = item(
        "same",
        "https://openai.com/one",
        "<b>One</b><script>bad()</script>",
    );
    input += &item("same", "https://openai.com/two", "Duplicate");
    input += &item("unsafe", "javascript:alert(1)", "Unsafe");
    for i in 0..120 {
        input += &item(
            &format!("id{i}"),
            &format!("https://openai.com/{i}"),
            "News",
        );
    }
    let items = parse_feed(rss(&input).as_bytes()).unwrap();
    assert_eq!(items.len(), 50);
    assert_eq!(items[0].title, "One");
    assert_eq!(items[0].description.as_deref(), Some("Hello & world"));
    assert_eq!(
        items[0].published_at.as_deref(),
        Some("2026-11-03T12:00:00Z")
    );
    assert!(!items.iter().any(|v| v.id == "openai:unsafe"));
}

#[test]
fn malformed_cache_is_visible_and_does_not_fetch() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("news-cache.json"), b"broken").unwrap();
    let client = NewsClient::new(dir.path().to_string_lossy().into_owned()).unwrap();
    assert_eq!(client.snapshot().failure().unwrap().kind, "cache");
}

async fn server() -> (
    String,
    tokio::sync::oneshot::Receiver<()>,
    tokio::sync::oneshot::Sender<String>,
) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/rss", listener.local_addr().unwrap());
    let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel::<String>();
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut input = [0; 4096];
        let amount = socket.read(&mut input).await.unwrap();
        assert!(amount > 0);
        let _ = seen_tx.send(());
        if let Ok(reply) = reply_rx.await {
            let _ = socket.write_all(reply.as_bytes()).await;
        }
    });
    (url, seen_rx, reply_tx)
}

fn response(status: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[tokio::test]
async fn refresh_cache_reload_and_failed_fetch_preserves_success() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(response(
            "200 OK",
            &rss(&item("one", "https://openai.com/one", "One")),
        ))
        .unwrap();
    let first = running.await.unwrap();
    assert_eq!(first.items.len(), 1);
    assert!(first.error.is_none());
    client.shutdown();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    assert_eq!(client.snapshot().items, first.items);
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(response("429 Too Many Requests", "slow down"))
        .unwrap();
    let failed = running.await.unwrap();
    assert_eq!(failed.failure().unwrap().kind, "rate_limited");
    assert_eq!(failed.items, first.items);
    assert_eq!(
        failed.sources[0].last_success_ms,
        first.sources[0].last_success_ms
    );
}

#[tokio::test]
async fn cancellation_duplicate_start_shutdown_and_late_reply() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    assert!(client.snapshot().refreshing);
    assert_eq!(client.refresh(None).await.failure().unwrap().kind, "busy");
    client.cancel_refresh();
    reply
        .send(response(
            "200 OK",
            &rss(&item("late", "https://openai.com/late", "Late")),
        ))
        .unwrap();
    let cancelled = running.await.unwrap();
    assert_eq!(cancelled.failure().unwrap().kind, "cancelled");
    assert!(cancelled.items.is_empty());
    assert!(!dir.path().join("news-cache.json").exists());
    client.shutdown();
    client.shutdown();
    assert_eq!(client.refresh(None).await.failure().unwrap().kind, "closed");
}

#[tokio::test]
async fn timeout_and_invalid_response_are_visible() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, _reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_millis(100)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "timeout");
    client.shutdown();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(response("200 OK", "<html>not rss</html>"))
        .unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "parse");
}

#[test]
fn atomic_failure_does_not_replace_previous_cache() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    std::fs::write(&path, b"previous").unwrap();
    let result = persist_cache(
        &path,
        &Cache {
            version: 1,
            items: vec![],
            last_success_ms: 12,
        },
        true,
    );
    assert!(result.is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"previous");
}

#[test]
fn cache_roundtrip_preserves_literal_angle_brackets() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let items = parse_feed(
        rss(&item(
            "one",
            "https://openai.com/one",
            "<p>&lt;example&gt; &amp; 3 &lt; 5</p>",
        ))
        .as_bytes(),
    )
    .unwrap();
    persist_cache(
        &path,
        &Cache {
            version: 1,
            items: items.clone(),
            last_success_ms: 12,
        },
        false,
    )
    .unwrap();
    assert_eq!(cached_items(&path), items);
}

#[test]
fn unicode_url_boundary_survives_cache_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let oversized = format!("https://openai.com/{}", "é".repeat(3000));
    assert!(oversized.len() <= 8192);
    assert!(Url::parse(&oversized).unwrap().as_str().len() > 8192);
    let valid = item("valid", "https://openai.com/valid", "Valid");
    let feed = rss(&format!(
        "{}{}",
        item("oversized", &oversized, "Oversized"),
        valid
    ));
    let items = parse_feed(feed.as_bytes()).unwrap();
    persist_cache(
        &path,
        &Cache {
            version: 1,
            items: items.clone(),
            last_success_ms: 1234,
        },
        false,
    )
    .unwrap();
    assert_eq!(cached_items(&path), items);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "openai:valid");
    assert_eq!(
        parse_feed(rss(&item("oversized", &oversized, "Oversized")).as_bytes())
            .unwrap_err()
            .kind,
        "parse"
    );

    let within_limit = format!("https://openai.com/{}", "é".repeat(1300));
    let items = parse_feed(rss(&item("unicode", &within_limit, "Unicode")).as_bytes()).unwrap();
    assert_eq!(items.len(), 1);
    persist_cache(
        &path,
        &Cache {
            version: 1,
            items: items.clone(),
            last_success_ms: 1234,
        },
        false,
    )
    .unwrap();
    assert_eq!(cached_items(&path), items);
}

#[tokio::test]
async fn dropped_refresh_and_shutdown_prevent_late_commit() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    running.abort();
    assert!(running.await.unwrap_err().is_cancelled());
    assert_eq!(client.snapshot().failure().unwrap().kind, "cancelled");
    assert!(!client.snapshot().refreshing);
    let _ = reply.send(response(
        "200 OK",
        &rss(&item("late", "https://openai.com/late", "Late")),
    ));
    client.shutdown();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    client.shutdown();
    let replacement = NewsClient::new(dir.path().to_string_lossy().into_owned()).unwrap();
    reply
        .send(response(
            "200 OK",
            &rss(&item("late", "https://openai.com/late", "Late")),
        ))
        .unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "closed");
    assert!(replacement.snapshot().items.is_empty());
    assert!(!dir.path().join("news-cache.json").exists());
}

#[tokio::test]
async fn redirects_and_oversized_responses_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply.send("HTTP/1.1 302 Found\r\nLocation: https://example.invalid/unwanted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned()).unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "http");
    client.shutdown();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            MAX_BYTES + 1
        ))
        .unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "too_large");
    assert!(!dir.path().join("news-cache.json").exists());
}

#[test]
fn latest_dates_and_link_fallback_identity() {
    let input = rss(&format!("{}{}<item><title>Latest</title><link>https://openai.com/latest</link><pubDate>Wed, 04 Nov 2026 12:00:00 GMT</pubDate></item>",
        item("old", "https://openai.com/old", "Old"), item("duplicate-url", "https://openai.com/old", "Duplicate")));
    let items = parse_feed(input.as_bytes()).unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0].id, "openai:https://openai.com/latest");
}

#[cfg(windows)]
#[test]
fn windows_atomic_replace_failure_preserves_old_file() {
    use std::os::windows::fs::OpenOptionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    std::fs::write(&path, b"previous").unwrap();
    // A real Windows file handle without FILE_SHARE_DELETE blocks replacement.
    let _held = OpenOptions::new()
        .read(true)
        .share_mode(0x1 | 0x2)
        .open(&path)
        .unwrap();
    let result = persist_cache(
        &path,
        &Cache {
            version: 1,
            items: vec![],
            last_success_ms: 12,
        },
        false,
    );
    assert_eq!(result.unwrap_err().kind, "cache");
    assert_eq!(std::fs::read(&path).unwrap(), b"previous");
}

#[tokio::test]
async fn every_fetch_failure_and_cancellation_keep_existing_cache() {
    let cases = [
        ("http", Some(response("500 Internal Server Error", "no"))),
        ("parse", Some(response("200 OK", "<html>no</html>"))),
        ("timeout", None),
        ("cancelled", None),
    ];
    for (kind, response) in cases {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("news-cache.json");
        let items =
            parse_feed(rss(&item("kept", "https://openai.com/kept", "Kept")).as_bytes()).unwrap();
        persist_cache(
            &path,
            &Cache {
                version: 1,
                items: items.clone(),
                last_success_ms: 1234,
            },
            false,
        )
        .unwrap();
        let previous_bytes = std::fs::read(&path).unwrap();
        let (url, seen, reply) = server().await;
        let client = NewsClient::new_for_test(dir.path(), url, Duration::from_millis(100)).unwrap();
        let running = {
            let client = client.clone();
            tokio::spawn(async move { client.refresh(None).await })
        };
        seen.await.unwrap();
        let mut reply = Some(reply);
        if let Some(response) = response {
            reply.take().unwrap().send(response).unwrap();
        } else if kind == "cancelled" {
            client.cancel_refresh();
        }
        let result = running.await.unwrap();
        drop(reply);
        assert_eq!(result.failure().unwrap().kind, kind);
        assert_eq!(result.items, items);
        assert_eq!(result.sources[0].last_success_ms, Some(1234));
        assert_eq!(std::fs::read(&path).unwrap(), previous_bytes);
    }
}

#[tokio::test]
async fn missing_content_length_still_enforces_body_limit() {
    let dir = tempfile::tempdir().unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(format!(
            "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{}",
            "x".repeat(MAX_BYTES + 1)
        ))
        .unwrap();
    assert_eq!(running.await.unwrap().failure().unwrap().kind, "too_large");
}

#[cfg(windows)]
#[tokio::test]
async fn cache_commit_failure_preserves_memory_and_disk() {
    use std::os::windows::fs::OpenOptionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let items =
        parse_feed(rss(&item("kept", "https://openai.com/kept", "Kept")).as_bytes()).unwrap();
    persist_cache(
        &path,
        &Cache {
            version: 1,
            items: items.clone(),
            last_success_ms: 1234,
        },
        false,
    )
    .unwrap();
    let previous = std::fs::read(&path).unwrap();
    let _held = OpenOptions::new()
        .read(true)
        .share_mode(0x1 | 0x2)
        .open(&path)
        .unwrap();
    let (url, seen, reply) = server().await;
    let client = NewsClient::new_for_test(dir.path(), url, Duration::from_secs(2)).unwrap();
    let running = {
        let client = client.clone();
        tokio::spawn(async move { client.refresh(None).await })
    };
    seen.await.unwrap();
    reply
        .send(response(
            "200 OK",
            &rss(&item("new", "https://openai.com/new", "New")),
        ))
        .unwrap();
    let result = running.await.unwrap();
    assert_eq!(result.failure().unwrap().kind, "cache");
    assert_eq!(result.items, items);
    assert_eq!(result.sources[0].last_success_ms, Some(1234));
    assert_eq!(std::fs::read(path).unwrap(), previous);
}
