use super::*;
use crate::sources::{rss::RssSource, Category};
use tokio::sync::oneshot;

const FEED: &[u8] = include_bytes!("../sources/fixtures/rss/openai.xml");

struct Server {
    url: String,
    seen: oneshot::Receiver<String>,
    reply: Option<oneshot::Sender<Vec<u8>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Server {
    async fn new() -> Self {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/feed", listener.local_addr().unwrap());
        let (seen_tx, seen) = oneshot::channel();
        let (reply, reply_rx) = oneshot::channel::<Vec<u8>>();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                if socket.read(&mut byte).await.unwrap_or(0) == 0 {
                    return;
                }
                request.push(byte[0]);
            }
            let _ = seen_tx.send(String::from_utf8(request).unwrap());
            if let Ok(response) = reply_rx.await {
                let _ = socket.write_all(&response).await;
            }
        });
        Self {
            url,
            seen,
            reply: Some(reply),
            task,
        }
    }
    async fn requested(&mut self) {
        let request = tokio::time::timeout(Duration::from_secs(3), &mut self.seen)
            .await
            .expect("request deadline")
            .unwrap()
            .to_ascii_lowercase();
        assert!(request.contains("user-agent: tokenlens-news/0.1\r\n"));
        assert!(request.contains("accept-encoding: gzip\r\n"));
        assert!(!request.contains("accept-encoding: identity"));
    }
    fn respond(&mut self, status: u16, headers: &str, body: &[u8]) {
        let mut response = format!(
            "HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(body);
        self.reply.take().unwrap().send(response).unwrap();
    }
    fn ok(&mut self) {
        self.respond(200, "Content-Type: application/rss+xml\r\n", FEED);
    }
    fn not_requested(&mut self) {
        assert_eq!(
            self.seen.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        );
    }
}

fn source(id: &str, category: Category, server: &Server) -> Box<dyn Source> {
    Box::new(RssSource::new(
        id,
        id,
        category,
        "https://example.com/",
        &server.url,
    ))
}

fn start(engine: &NewsEngine, ids: Option<Vec<String>>) -> tokio::task::JoinHandle<NewsSnapshot> {
    let engine = engine.clone();
    tokio::spawn(async move { engine.refresh(ids).await })
}

struct LargeBodySource(Box<dyn Source>);

#[tokio::test]
async fn gzip_body_is_decoded_before_parse_and_size_limit() {
    let cases: [(&[u8], bool, Option<&str>); 3] = [
        (
            include_bytes!("../sources/fixtures/rss/rss-normal.xml.gz"),
            false,
            None,
        ),
        (
            include_bytes!("../sources/fixtures/rss/rss-five-mib.xml.gz"),
            false,
            Some("too_large"),
        ),
        (
            include_bytes!("../sources/fixtures/rss/rss-five-mib.xml.gz"),
            true,
            None,
        ),
    ];
    for (body, large_limit, expected_error) in cases {
        assert!(body.len() < 4 * 1024 * 1024);
        let directory = tempfile::tempdir().unwrap();
        let mut server = Server::new().await;
        let feed = source("gzip", Category::Official, &server);
        let feed = if large_limit {
            Box::new(LargeBodySource(feed)) as Box<dyn Source>
        } else {
            feed
        };
        let engine = NewsEngine::new(directory.path(), vec![feed]).unwrap();
        let task = start(&engine, None);
        server.requested().await;
        server.respond(
            200,
            "Content-Type: application/rss+xml\r\nContent-Encoding: gzip\r\n",
            body,
        );
        let snapshot = task.await.unwrap();
        assert_eq!(
            snapshot.sources[0].error.as_ref().map(|e| e.kind.as_str()),
            expected_error
        );
        if expected_error.is_none() {
            assert_eq!(snapshot.items.len(), 1);
            assert_eq!(snapshot.items[0].id, "gzip:one");
        } else {
            assert!(!directory.path().join("news-cache.json").exists());
        }
    }
}

impl Source for LargeBodySource {
    fn info(&self) -> crate::sources::SourceInfo {
        self.0.info()
    }
    fn url(&self, now_ms: i64) -> String {
        self.0.url(now_ms)
    }
    fn accepts(&self) -> &'static [&'static str] {
        self.0.accepts()
    }
    fn max_body_bytes(&self) -> usize {
        16 * 1024 * 1024
    }
    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, crate::sources::ParseError> {
        self.0.parse(body)
    }
}

#[tokio::test]
async fn declared_body_limit_applies_to_content_length_and_streaming() {
    let mut body = std::str::from_utf8(FEED).unwrap().to_owned();
    body.push_str(&" ".repeat(5 * 1024 * 1024 - body.len()));
    for declared_large in [true, false] {
        for with_length in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let mut server = Server::new().await;
            let feed = source("test", Category::Official, &server);
            let feed = if declared_large {
                Box::new(LargeBodySource(feed)) as Box<dyn Source>
            } else {
                feed
            };
            let engine = NewsEngine::new(dir.path(), vec![feed]).unwrap();
            let running = start(&engine, None);
            server.requested().await;
            let length = if with_length {
                format!("Content-Length: {}\r\n", body.len())
            } else {
                String::new()
            };
            server.reply.take().unwrap().send(format!("HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\n{length}Connection: close\r\n\r\n{body}").into_bytes()).unwrap();
            let snapshot = running.await.unwrap();
            if declared_large {
                assert!(
                    snapshot.sources[0].error.is_none(),
                    "length={with_length}: {:?}",
                    snapshot.sources[0].error
                );
                assert_eq!(snapshot.items.len(), 3);
                assert_eq!(
                    load_cache(&dir.path().join("news-cache.json"))
                        .unwrap()
                        .sources["test"]
                        .items
                        .len(),
                    3
                );
            } else {
                assert_eq!(
                    snapshot.sources[0].error.as_ref().unwrap().kind,
                    "too_large"
                );
                assert!(!dir.path().join("news-cache.json").exists());
            }
        }
    }
}

#[tokio::test]
async fn four_concurrent_sources_commit_independently_and_refill_slots() {
    let dir = tempfile::tempdir().unwrap();
    let mut servers = Vec::new();
    for _ in 0..6 {
        servers.push(Server::new().await);
    }
    let sources = servers
        .iter()
        .enumerate()
        .map(|(i, s)| source(&format!("s{i}"), Category::Official, s))
        .collect();
    let engine = NewsEngine::new(dir.path(), sources).unwrap();
    let running = start(&engine, None);
    for s in &mut servers[..4] {
        s.requested().await;
    }
    servers[4].not_requested();
    servers[5].not_requested();
    assert!(engine.snapshot().sources.iter().all(|s| s.refreshing));
    assert_eq!(engine.refresh(None).await.error.unwrap().kind, "busy");
    servers[0].ok();
    servers[4].requested().await;
    let snapshot = engine.snapshot();
    assert!(snapshot.sources[0].last_success_ms.is_some());
    assert!(!snapshot.sources[0].refreshing);
    let disk = load_cache(&dir.path().join("news-cache.json")).unwrap();
    assert_eq!(disk.sources.len(), 1);
    assert!(disk.sources.contains_key("s0"));
    servers[1].ok();
    servers[5].requested().await;
    for s in &mut servers[2..] {
        s.ok();
    }
    let result = running.await.unwrap();
    assert!(!result.refreshing);
    assert!(result
        .sources
        .iter()
        .all(|s| s.last_success_ms.is_some() && s.error.is_none()));
    assert_eq!(
        load_cache(&dir.path().join("news-cache.json"))
            .unwrap()
            .sources
            .len(),
        6
    );
}

#[tokio::test]
async fn partial_failure_does_not_affect_other_sources() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = Server::new().await;
    let mut b = Server::new().await;
    let old_items = normalise_items(
        "b",
        vec![raw("kept", "https://example.com/old-b", None)],
        true,
    )
    .unwrap();
    save_cache(
        &dir.path().join("news-cache.json"),
        &Cache {
            sources: BTreeMap::from([(
                "b".into(),
                SourceCache {
                    items: old_items.clone(),
                    last_success_ms: Some(55),
                },
            )]),
            ..Cache::default()
        },
    )
    .unwrap();
    let engine = NewsEngine::new(
        dir.path(),
        vec![
            source("a", Category::Official, &a),
            source("b", Category::Official, &b),
        ],
    )
    .unwrap();
    let running = start(&engine, None);
    a.requested().await;
    b.requested().await;
    a.ok();
    b.respond(500, "", b"failure");
    let result = running.await.unwrap();
    assert!(result.error.is_none());
    assert_eq!(result.sources[1].error.as_ref().unwrap().kind, "http");
    assert!(result.sources[0].last_success_ms.is_some());
    assert!(result.items.iter().any(|i| i.source_id == "a"));
    assert!(result.items.contains(&old_items[0]));
    assert_eq!(result.sources[1].last_success_ms, Some(55));
    let json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("news-cache.json")).unwrap())
            .unwrap();
    assert_eq!(json["sources"]["b"]["last_success_ms"], 55);
    assert_eq!(
        load_cache(&dir.path().join("news-cache.json"))
            .unwrap()
            .sources["b"]
            .items,
        old_items
    );
    assert!(!String::from_utf8(serde_json::to_vec(&json).unwrap())
        .unwrap()
        .contains("error"));
}

#[tokio::test]
async fn explicit_refresh_ignores_unknown_disabled_and_duplicate_ids() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = Server::new().await;
    let mut b = Server::new().await;
    let mut c = Server::new().await;
    let engine = NewsEngine::new(
        dir.path(),
        vec![
            source("a", Category::Official, &a),
            source("b", Category::Official, &b),
            source("c", Category::Official, &c),
        ],
    )
    .unwrap();
    engine.set_source_enabled("c", false);
    let running = start(
        &engine,
        Some(vec!["b".into(), "b".into(), "c".into(), "unknown".into()]),
    );
    b.requested().await;
    a.not_requested();
    c.not_requested();
    b.ok();
    let result = running.await.unwrap();
    assert!(result.sources[0].last_success_ms.is_none());
    assert!(result.sources[1].last_success_ms.is_some());
    assert!(!result.sources[2].enabled);
    assert!(!engine.refresh(Some(vec![])).await.refreshing);
}

#[tokio::test]
async fn disabling_a_queued_source_prevents_its_request() {
    let dir = tempfile::tempdir().unwrap();
    let mut servers = Vec::new();
    for _ in 0..6 {
        servers.push(Server::new().await);
    }
    let engine = NewsEngine::new(
        dir.path(),
        servers
            .iter()
            .enumerate()
            .map(|(i, s)| source(&format!("s{i}"), Category::Official, s))
            .collect(),
    )
    .unwrap();
    let running = start(&engine, None);
    for server in &mut servers[..4] {
        server.requested().await;
    }
    engine.set_source_enabled("s4", false);
    servers[0].ok();
    // s5 can start only if the disabled s4 was skipped while refilling the slot.
    servers[5].requested().await;
    servers[4].not_requested();
    for server in &mut servers[1..4] {
        server.ok();
    }
    servers[5].ok();
    let snapshot = running.await.unwrap();
    assert!(!snapshot.sources[4].enabled);
    assert!(!snapshot.sources[4].refreshing);
    assert!(snapshot.sources[4].last_success_ms.is_none());
}

#[tokio::test]
async fn cancel_preserves_committed_sources_and_blocks_late_commits() {
    let dir = tempfile::tempdir().unwrap();
    let mut servers = Vec::new();
    for _ in 0..6 {
        servers.push(Server::new().await);
    }
    let engine = NewsEngine::new(
        dir.path(),
        servers
            .iter()
            .enumerate()
            .map(|(i, s)| source(&format!("s{i}"), Category::Official, s))
            .collect(),
    )
    .unwrap();
    let running = start(&engine, None);
    for s in &mut servers[..4] {
        s.requested().await;
    }
    servers[0].ok();
    servers[4].requested().await;
    servers[5].not_requested();
    let before = std::fs::read(dir.path().join("news-cache.json")).unwrap();
    engine.cancel_refresh();
    for s in &mut servers[1..5] {
        s.ok();
    }
    let result = running.await.unwrap();
    servers[5].not_requested();
    assert!(!result.refreshing);
    assert!(result.sources[0].error.is_none());
    assert!(result.sources[1..]
        .iter()
        .all(|s| s.error.as_ref().unwrap().kind == "cancelled"));
    assert_eq!(
        std::fs::read(dir.path().join("news-cache.json")).unwrap(),
        before
    );
    engine.shutdown();
    let reopened = NewsEngine::new(dir.path(), crate::sources::registry()).unwrap();
    assert!(reopened
        .snapshot()
        .sources
        .iter()
        .all(|s| s.error.is_none()));
}

#[tokio::test]
async fn http_status_and_content_type_failures_are_classified_before_parse() {
    for (id, status, headers, kind) in [
        (
            "github-new",
            403,
            "x-ratelimit-remaining: 0\r\n",
            "rate_limited",
        ),
        (
            "gh-release:openai/codex",
            403,
            "x-ratelimit-remaining: 0\r\n",
            "rate_limited",
        ),
        ("openai", 403, "x-ratelimit-remaining: 0\r\n", "http"),
        ("github-new", 403, "x-ratelimit-remaining: 1\r\n", "http"),
        ("openai", 429, "", "rate_limited"),
        ("openai", 201, "", "http"),
        (
            "openai",
            302,
            "Location: https://example.invalid/unwanted\r\n",
            "http",
        ),
        ("openai", 200, "Content-Type: text/html\r\n", "content_type"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let mut server = Server::new().await;
        let engine =
            NewsEngine::new(dir.path(), vec![source(id, Category::Official, &server)]).unwrap();
        let running = start(&engine, None);
        server.requested().await;
        server.respond(status, headers, FEED);
        let result = running.await.unwrap();
        assert!(result.error.is_none());
        assert_eq!(
            result.sources[0].error.as_ref().unwrap().kind,
            kind,
            "{id} {status}"
        );
        assert!(!dir.path().join("news-cache.json").exists());
    }
}

#[tokio::test]
async fn enabled_state_survives_restart_and_retains_hidden_cache() {
    let dir = tempfile::tempdir().unwrap();
    let mut server = Server::new().await;
    let engine = NewsEngine::new(
        dir.path(),
        vec![source("openai", Category::Official, &server)],
    )
    .unwrap();
    let running = start(&engine, None);
    server.requested().await;
    server.ok();
    let before = running.await.unwrap().items;
    assert!(!before.is_empty());
    assert!(engine.set_source_enabled("openai", false).items.is_empty());
    engine.shutdown();
    let engine = NewsEngine::new(
        dir.path(),
        vec![source("openai", Category::Official, &server)],
    )
    .unwrap();
    assert!(!engine.snapshot().sources[0].enabled);
    assert!(engine.refresh(None).await.items.is_empty());
    assert_eq!(engine.set_source_enabled("openai", true).items, before);
    engine.shutdown();
    let reopened = NewsEngine::new(
        dir.path(),
        vec![source("openai", Category::Official, &server)],
    )
    .unwrap();
    assert!(reopened.snapshot().sources[0].enabled);
    assert_eq!(reopened.snapshot().items, before);
}

#[test]
fn cache_v1_migration_is_in_memory_until_commit_and_unknown_versions_are_visible() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let legacy = br#"{"version":1,"items":[{"id":"old","title":"A <literal>","url":"https://example.com/old","published_at":null,"description":null}],"last_success_ms":123}"#;
    std::fs::write(&path, legacy).unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry()).unwrap();
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.items[0].id, "openai:old");
    assert_eq!(snapshot.items[0].source_id, "openai");
    assert_eq!(snapshot.items[0].title, "A <literal>");
    assert_eq!(snapshot.sources[0].last_success_ms, Some(123));
    assert_eq!(std::fs::read(&path).unwrap(), legacy);
    engine.set_source_enabled("qbitai", false);
    assert_eq!(load_cache(&path).unwrap().version, 2);
    engine.shutdown();
    for invalid in [
        br#"{"version":99}"#.as_slice(),
        br#"{"version":2,"sources":{},"disabled":"no"}"#.as_slice(),
    ] {
        std::fs::write(&path, invalid).unwrap();
        let engine = NewsEngine::new(dir.path(), crate::sources::registry()).unwrap();
        assert_eq!(engine.snapshot().error.unwrap().kind, "cache");
        assert_eq!(std::fs::read(&path).unwrap(), invalid);
        engine.shutdown();
    }
}

fn raw(id: &str, url: &str, date: Option<&str>) -> RawItem {
    RawItem {
        kind: None,
        native_id: id.into(),
        title: "<b>Title &amp; text</b><script>hidden</script>".into(),
        url: url.into(),
        published_at: date.map(String::from),
        description: Some("<p>Description</p>".into()),
        popularity: Some(crate::sources::Popularity {
            kind: PopularityKind::Stars,
            value: 42,
        }),
    }
}

#[test]
fn release_plain_text_survives_normalisation() {
    let source = crate::sources::github::releases()
        .into_iter()
        .find(|source| source.info().id == "gh-release:openai/codex")
        .unwrap();
    let mut fixture: serde_json::Value =
        serde_json::from_slice(include_bytes!("../sources/fixtures/github/releases.json")).unwrap();
    fixture[0]["body"] = serde_json::json!("Supports Vec<String> now.");
    let raw = source
        .parse(&serde_json::to_vec(&fixture).unwrap())
        .unwrap();
    let items = normalise_items(&source.info().id, raw, source.text_is_html()).unwrap();
    assert_eq!(
        items[0].description.as_deref(),
        Some("Supports Vec<String> now.")
    );
}

#[test]
fn hn_script_literal_survives_normalisation() {
    let source = crate::sources::hackernews::ai();
    let mut fixture: serde_json::Value = serde_json::from_slice(include_bytes!(
        "../sources/fixtures/hackernews/front-page.json"
    ))
    .unwrap();
    fixture["hits"][0]["title"] = serde_json::json!("AI <script> agents keep running.");
    let raw = source
        .parse(&serde_json::to_vec(&fixture).unwrap())
        .unwrap();
    let items = normalise_items(&source.info().id, raw, source.text_is_html()).unwrap();
    let item = items
        .iter()
        .find(|item| item.id == "hn-ai:50385272")
        .unwrap();
    assert_eq!(item.title, "AI <script> agents keep running.");
}

#[test]
fn html_feed_tags_are_removed_during_normalisation() {
    let source = crate::sources::rss::feeds().remove(0);
    let fixture = include_str!("../sources/fixtures/rss/rss-normal.xml")
        .replace(
            "<title>One</title>",
            "<title><![CDATA[<b>Title &amp; text</b>]]></title>",
        )
        .replace(
            "<description>Summary</description>",
            "<description><![CDATA[<p>Summary</p><script>hidden</script>]]></description>",
        );
    let raw = source.parse(fixture.as_bytes()).unwrap();
    let items = normalise_items(&source.info().id, raw, source.text_is_html()).unwrap();
    assert_eq!(items[0].title, "Title & text");
    assert_eq!(items[0].description.as_deref(), Some("Summary"));
}

#[test]
fn json_text_normalisation_preserves_literals_and_limits() {
    let sources: Vec<_> = crate::sources::registry()
        .into_iter()
        .filter(|source| source.accepts() == ["application/json"])
        .collect();
    assert_eq!(sources.len(), 11);
    for source in sources {
        let mut literal = raw("literal", "https://example.com/literal", None);
        literal.title = " \tSupports Vec<String>\n now. \u{1} &amp; ".into();
        literal.description =
            Some(" \tUse <script> literally.\u{7}\n Keep &amp; unchanged. ".into());
        let mut long = raw("long", "https://example.com/long", None);
        long.title = "字".repeat(513);
        long.description = Some("文".repeat(4001));
        let mut controls = raw("controls", "https://example.com/controls", None);
        controls.title = "A \u{1} B".into();
        controls.description = Some(" \u{1} \u{7} ".into());
        let items = normalise_items(
            &source.info().id,
            vec![literal, long, controls],
            source.text_is_html(),
        )
        .unwrap();
        assert_eq!(
            items[0].title,
            "Supports Vec<String> now. &amp;",
            "{}",
            source.info().id
        );
        assert_eq!(
            items[0].description.as_deref(),
            Some("Use <script> literally. Keep &amp; unchanged.")
        );
        assert_eq!(items[1].title, "字".repeat(512));
        assert_eq!(
            items[1].description.as_deref(),
            Some("文".repeat(4000).as_str())
        );
        assert_eq!(items[2].title, "A B");
        assert_eq!(items[2].description, None);
    }
}

#[test]
fn per_source_limits_identity_and_framework_validation() {
    let mut input = vec![
        raw("duplicate", "https://example.com/first", None),
        raw("duplicate", "https://example.com/second", None),
        raw("unsafe", "javascript:bad", None),
    ];
    for n in 0..80 {
        input.push(raw(
            &n.to_string(),
            &format!("https://example.com/{n}"),
            Some("2026-11-05T10:00:00-05:00"),
        ));
    }
    let items = normalise_items("source", input, true).unwrap();
    assert_eq!(items.len(), 50);
    assert_eq!(items[0].id, "source:0");
    assert_eq!(items[0].title, "Title & text");
    assert_eq!(items[0].description.as_deref(), Some("Description"));
    assert_eq!(
        items[0].published_at.as_deref(),
        Some("2026-11-05T15:00:00Z")
    );
    assert_eq!(items[0].popularity_kind.as_deref(), Some("stars"));
    assert_eq!(items[0].popularity, Some(42));
    let duplicates = normalise_items(
        "s",
        vec![
            raw("same", "https://example.com/1", None),
            raw("same", "https://example.com/2", None),
        ],
        true,
    )
    .unwrap();
    assert_eq!(duplicates.len(), 1);
    assert_eq!(duplicates[0].id, "s:same");
    assert_eq!(
        normalise_items("s", vec![raw("bad", "file:///bad", None)], true)
            .unwrap_err()
            .kind,
        "parse"
    );
    assert!(normalise_items("s", vec![], true).unwrap().is_empty());
}

#[test]
fn normalised_text_can_always_be_reloaded_from_cache() {
    let dir = tempfile::tempdir().unwrap();
    let mut item = raw("controls", "https://example.com/controls", None);
    item.title = "Title\u{1} text".into();
    item.description = Some("Description\u{7}".into());
    let cache = Cache {
        sources: BTreeMap::from([(
            "s".into(),
            SourceCache {
                items: normalise_items("s", vec![item], true).unwrap(),
                last_success_ms: Some(1),
            },
        )]),
        ..Cache::default()
    };
    let path = dir.path().join("news-cache.json");
    save_cache(&path, &cache).unwrap();
    assert!(load_cache(&path).is_ok());
}

#[test]
fn snapshot_url_dedup_priority_also_in_and_date_sorting() {
    let dir = tempfile::tempdir().unwrap();
    let source = |id, category| {
        Box::new(RssSource::new(
            id,
            id,
            category,
            "https://example.com/",
            "https://example.invalid/",
        )) as Box<dyn Source>
    };
    let engine = NewsEngine::new(
        dir.path(),
        vec![
            source("community", Category::Community),
            source("tools", Category::Tools),
            source("chinese", Category::Chinese),
            source("official", Category::Official),
            source("official2", Category::Official),
        ],
    )
    .unwrap();
    {
        let mut state = engine.inner.state.lock().unwrap();
        for id in ["community", "tools", "chinese", "official", "official2"] {
            let items = normalise_items(
                id,
                vec![
                    raw(
                        "same",
                        "HTTPS://EXAMPLE.COM/article/?utm_source=a&keep=1#fragment",
                        Some("2026-11-05T12:00:00Z"),
                    ),
                    raw("undated", &format!("https://example.com/{id}"), None),
                ],
                true,
            )
            .unwrap();
            state.cache.sources.insert(
                id.into(),
                SourceCache {
                    items,
                    last_success_ms: Some(1),
                },
            );
        }
        let official = state.cache.sources.get_mut("official").unwrap();
        official.items[0].url = "https://example.com/article?keep=1".into();
        official.items.push(
            normalise_items(
                "official",
                vec![raw(
                    "newest",
                    "https://example.com/new",
                    Some("2026-11-05T08:00:01-05:00"),
                )],
                true,
            )
            .unwrap()
            .remove(0),
        );
    }
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.items.len(), 7);
    assert_eq!(snapshot.items[0].id, "official:newest");
    assert_eq!(snapshot.items[1].source_id, "official");
    assert_eq!(
        snapshot.items[1].also_in,
        ["official2", "chinese", "tools", "community"]
    );
    assert_eq!(
        snapshot.items[2..]
            .iter()
            .map(|i| i.source_id.as_str())
            .collect::<Vec<_>>(),
        ["community", "tools", "chinese", "official", "official2"]
    );
    assert!(engine
        .inner
        .state
        .lock()
        .unwrap()
        .cache
        .sources
        .values()
        .all(|s| s.items.iter().all(|i| i.also_in.is_empty())));
    assert_eq!(
        canonical_url("https://example.com/path/"),
        canonical_url("https://EXAMPLE.COM/path#f")
    );
    assert_ne!(
        canonical_url("https://example.com/path?a=1"),
        canonical_url("https://example.com/path?a=2")
    );
}

#[tokio::test]
async fn shutdown_and_dropped_refresh_release_lock_and_forbid_late_commit() {
    for shutdown in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let mut server = Server::new().await;
        let engine = NewsEngine::new(
            dir.path(),
            vec![source("openai", Category::Official, &server)],
        )
        .unwrap();
        let running = start(&engine, None);
        server.requested().await;
        if shutdown {
            engine.shutdown();
            engine.shutdown();
            server.ok();
            assert_eq!(running.await.unwrap().error.unwrap().kind, "closed");
            assert_eq!(engine.refresh(None).await.error.unwrap().kind, "closed");
            assert_eq!(
                engine
                    .set_source_enabled("openai", false)
                    .error
                    .unwrap()
                    .kind,
                "closed"
            );
        } else {
            running.abort();
            assert!(running.await.unwrap_err().is_cancelled());
            server.ok();
            assert!(!engine.snapshot().refreshing);
            assert_eq!(
                engine.snapshot().sources[0].error.as_ref().unwrap().kind,
                "cancelled"
            );
            engine.shutdown();
        }
        let replacement = NewsEngine::new(dir.path(), crate::sources::registry()).unwrap();
        assert!(replacement.snapshot().items.is_empty());
        assert!(!dir.path().join("news-cache.json").exists());
    }
}
