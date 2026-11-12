use super::*;
use crate::sources::{rss::RssSource, Category};
use tokio::sync::oneshot;

const FEED: &[u8] = include_bytes!("../sources/fixtures/rss/openai.xml");

const D26B_NOW: i64 = 1794000000000;
const D26B_MONTH: i64 = 30 * 24 * 60 * 60 * 1000;

fn d26b_open(path: &Path) -> NewsEngine {
    NewsEngine::new(path, crate::sources::registry(), D26B_NOW).unwrap()
}

fn d26b_seed(path: &Path) {
    let mut cache = old_v2_cache();
    cache["sources"]
        .as_object_mut()
        .unwrap()
        .retain(|id, _| id == "openai");
    std::fs::write(
        path.join("news-cache.json"),
        serde_json::to_vec(&cache).unwrap(),
    )
    .unwrap();
}

fn d26b_disk(path: &Path) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(path.join("news-state.json")).unwrap()).unwrap()
}

fn d26b_commit(engine: &NewsEngine, items: Vec<NewsItem>) {
    engine.inner.state.lock().unwrap().active = Some((1, CancellationToken::new()));
    engine.inner.commit(1, 0, Ok(items), D26B_NOW + 100);
    engine.inner.state.lock().unwrap().active = None;
}

#[test]
fn d26b_missing_state_is_empty_and_noops_do_not_write() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let snap = engine.snapshot();
    assert!(snap.state_error.is_none());
    assert!(snap.starred.is_empty());
    assert!(snap.items.iter().all(|i| !i.read && !i.starred));
    engine.set_read(vec![], true, D26B_NOW);
    engine.set_read(vec!["unknown".into()], true, D26B_NOW);
    engine.set_starred("unknown", true, D26B_NOW);
    assert!(!dir.path().join("news-state.json").exists());
}

#[test]
fn d26b_persistence_read_timestamp_and_unread() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let id = engine.snapshot().items[0].id.clone();
    assert!(engine.set_read(vec![id.clone()], true, D26B_NOW).items[0].read);
    engine.set_read(vec![id.clone()], true, D26B_NOW + 1);
    assert_eq!(d26b_disk(dir.path())["read"][&id], D26B_NOW);
    let snap = engine.set_starred(&id, true, D26B_NOW + 2);
    assert!(snap.items[0].starred);
    assert_eq!(snap.starred, snap.items);
    let stored = d26b_disk(dir.path());
    println!("D26B synthetic state: {stored}");
    assert!(stored["starred"][&id]["item"].get("read").is_none());
    assert!(stored["starred"][&id]["item"].get("starred").is_none());
    engine.shutdown();
    let reopened = d26b_open(dir.path());
    assert!(reopened.snapshot().items[0].read);
    assert!(reopened.snapshot().items[0].starred);
    assert_eq!(reopened.snapshot().starred.len(), 1);
    assert!(
        !reopened
            .set_read(vec![id.clone()], false, D26B_NOW + 3)
            .items[0]
            .read
    );
    assert!(d26b_disk(dir.path())["read"].get(&id).is_none());
    assert!(reopened
        .set_starred(&id, false, D26B_NOW + 4)
        .starred
        .is_empty());
}

#[test]
fn d26b_corrupt_state_is_sticky_read_only_and_preserves_bytes() {
    for bytes in [
        b"{broken".as_slice(),
        br#"{"version":2,"read":{},"starred":{}}"#,
    ] {
        let dir = tempfile::tempdir().unwrap();
        d26b_seed(dir.path());
        let path = dir.path().join("news-state.json");
        std::fs::write(&path, bytes).unwrap();
        let engine = d26b_open(dir.path());
        let snap = engine.snapshot();
        assert_eq!(snap.state_error.unwrap().kind, "cache");
        assert!(snap.error.is_none());
        assert_eq!(snap.items.len(), 1);
        let id = snap.items[0].id.clone();
        for snap in [
            engine.set_read(vec![id.clone()], true, D26B_NOW),
            engine.set_starred(&id, true, D26B_NOW),
        ] {
            assert_eq!(snap.state_error.unwrap().kind, "cache");
            assert!(!snap.items[0].read);
            assert!(!snap.items[0].starred);
        }
        assert!(engine
            .set_source_enabled("openai", false)
            .state_error
            .is_some());
        assert!(engine
            .set_source_enabled("openai", true)
            .state_error
            .is_some());
        let mut updated = engine.snapshot().items;
        updated[0].title = "Fresh despite bad state".into();
        d26b_commit(&engine, updated);
        assert_eq!(engine.snapshot().items[0].title, "Fresh despite bad state");
        assert!(engine.snapshot().state_error.is_some());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
}

#[test]
fn d26b_cleanup_uses_strict_thirty_day_boundary_and_all_caches() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let id = engine.snapshot().items[0].id.clone();
    engine.shutdown();
    std::fs::write(
        dir.path().join("news-state.json"),
        serde_json::to_vec(&serde_json::json!({
            "version":1,"read":{
                "gone:boundary": D26B_NOW - D26B_MONTH,
                "gone:old": D26B_NOW - D26B_MONTH - 1,
                id.clone(): D26B_NOW - D26B_MONTH - 1
            },"starred":{}
        }))
        .unwrap(),
    )
    .unwrap();
    let engine = d26b_open(dir.path());
    engine.set_source_enabled("openai", false);
    // Disabled caches also protect a read record; toggling read is a successful state write.
    engine.set_read(vec![id.clone()], true, D26B_NOW);
    let read = d26b_disk(dir.path())["read"].clone();
    assert_eq!(read["gone:boundary"], D26B_NOW - D26B_MONTH);
    assert!(read.get("gone:old").is_none());
    assert_eq!(read[&id], D26B_NOW - D26B_MONTH - 1);
}

#[test]
fn d26b_starred_copy_updates_survives_disappearance_and_disable() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let id = engine.snapshot().items[0].id.clone();
    let mut items = engine.snapshot().items;
    engine.set_starred(&id, true, D26B_NOW);
    items[0].title = "Updated title".into();
    d26b_commit(&engine, items);
    assert_eq!(engine.snapshot().starred[0].title, "Updated title");
    assert_eq!(
        d26b_disk(dir.path())["starred"][&id]["starred_at_ms"],
        D26B_NOW
    );
    engine.set_source_enabled("openai", false);
    assert!(engine.snapshot().items.is_empty());
    assert_eq!(engine.snapshot().starred[0].title, "Updated title");
    engine.set_source_enabled("openai", true);
    d26b_commit(&engine, Vec::new());
    assert!(engine.snapshot().items.is_empty());
    assert_eq!(engine.snapshot().starred[0].title, "Updated title");
    engine.shutdown();
    let reopened = d26b_open(dir.path());
    assert_eq!(reopened.snapshot().starred[0].title, "Updated title");
    assert!(
        reopened
            .set_read(vec![id.clone()], true, D26B_NOW + 1)
            .starred[0]
            .read
    );
    reopened.set_starred(&id, true, D26B_NOW + 2);
    assert_eq!(
        d26b_disk(dir.path())["starred"][&id]["starred_at_ms"],
        D26B_NOW
    );
}

#[test]
fn d26b_starred_order_flags_not_in_cache_and_closed() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let mut items = engine.snapshot().items;
    let first = items[0].id.clone();
    let mut other = items[0].clone();
    other.id = "openai:other".into();
    other.url = "https://example.com/other".into();
    let second = other.id.clone();
    items.push(other);
    d26b_commit(&engine, items);
    engine.set_starred(&first, true, D26B_NOW);
    let snap = engine.set_starred(&second, true, D26B_NOW + 1);
    assert_eq!(
        snap.starred.iter().map(|i| &i.id).collect::<Vec<_>>(),
        [&second, &first]
    );
    engine.set_read(vec![first.clone(), second.clone()], true, D26B_NOW + 2);
    engine.set_source_enabled("openai", false);
    let json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("news-cache.json")).unwrap())
            .unwrap();
    for item in json["sources"]["openai"]["items"].as_array().unwrap() {
        assert!(item.get("read").is_none());
        assert!(item.get("starred").is_none());
    }
    engine.shutdown();
    assert_eq!(
        engine
            .set_read(vec![first.clone()], false, D26B_NOW)
            .error
            .unwrap()
            .kind,
        "closed"
    );
    assert_eq!(
        engine
            .set_starred(&first, false, D26B_NOW)
            .error
            .unwrap()
            .kind,
        "closed"
    );
}

#[cfg(windows)]
#[test]
fn d26b_state_write_failure_rolls_back_and_refresh_still_commits_cache() {
    use std::os::windows::fs::OpenOptionsExt;
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let id = engine.snapshot().items[0].id.clone();
    engine.set_read(vec![id.clone()], true, D26B_NOW);
    engine.set_starred(&id, true, D26B_NOW);
    let previous = std::fs::read(dir.path().join("news-state.json")).unwrap();
    let held = OpenOptions::new()
        .read(true)
        .share_mode(0x1 | 0x2)
        .open(dir.path().join("news-state.json"))
        .unwrap();
    assert!(engine
        .set_read(vec![], true, D26B_NOW)
        .state_error
        .is_none());
    assert!(engine
        .set_starred("unknown", true, D26B_NOW)
        .state_error
        .is_none());
    let snap = engine.set_read(vec![id.clone()], false, D26B_NOW + 1);
    assert_eq!(snap.state_error.unwrap().kind, "cache");
    assert!(snap.items[0].read);
    let snap = engine.set_starred(&id, false, D26B_NOW + 1);
    assert_eq!(snap.state_error.unwrap().kind, "cache");
    assert!(snap.items[0].starred);
    let mut items = engine.snapshot().items;
    items[0].title = "Cache committed".into();
    d26b_commit(&engine, items);
    let snap = engine.snapshot();
    assert!(snap.error.is_none());
    assert!(snap.sources[0].error.is_none());
    assert_eq!(snap.items[0].title, "Cache committed");
    assert!(snap.state_error.is_some());
    assert_eq!(
        std::fs::read(dir.path().join("news-state.json")).unwrap(),
        previous
    );
    drop(held);
    engine.shutdown();
    let reopened = d26b_open(dir.path());
    assert_eq!(reopened.snapshot().items[0].title, "Cache committed");
    // Once absent from cache, the last successfully persisted copy is authoritative.
    d26b_commit(&reopened, Vec::new());
    assert_ne!(reopened.snapshot().starred[0].title, "Cache committed");
}

#[test]
fn d26b_starred_accepts_only_snapshot_primary_and_keeps_also_in() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("news-cache.json"),
        serde_json::to_vec(&old_v2_cache()).unwrap(),
    )
    .unwrap();
    let engine = d26b_open(dir.path());
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.items.len(), 1);
    let id = snapshot.items[0].id.clone();
    assert_eq!(snapshot.items[0].also_in, ["gh-release:openai/codex"]);
    assert!(engine
        .set_starred("gh-release:openai/codex:old", true, D26B_NOW)
        .starred
        .is_empty());
    assert!(!dir.path().join("news-state.json").exists());
    engine.set_starred(&id, true, D26B_NOW);
    assert_eq!(
        d26b_disk(dir.path())["starred"][&id]["item"]["also_in"],
        serde_json::json!(["gh-release:openai/codex"])
    );
    engine.set_source_enabled("openai", false);
    engine.set_starred(&id, true, D26B_NOW + 1);
    engine.shutdown();
    let reopened = d26b_open(dir.path());
    assert!(reopened.snapshot().state_error.is_none());
    assert_eq!(
        reopened.snapshot().starred[0].also_in,
        ["gh-release:openai/codex"]
    );
    reopened.set_starred(&id, false, D26B_NOW + 2);
    // Disabled main items cannot be newly starred even though their source cache is retained.
    assert!(reopened
        .set_starred(&id, true, D26B_NOW + 3)
        .starred
        .is_empty());
}

#[tokio::test]
async fn d26b_read_and_starred_during_real_refresh_survive_its_commit() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let mut server = Server::new().await;
    let engine = NewsEngine::new(
        dir.path(),
        vec![source("openai", Category::Official, &server)],
        D26B_NOW,
    )
    .unwrap();
    let id = engine.snapshot().items[0].id.clone();
    let running = start(&engine, None);
    server.requested().await;
    let read = engine.set_read(vec![id.clone()], true, D26B_NOW);
    assert!(read.refreshing);
    assert!(read.error.is_none());
    let starred = engine.set_starred(&id, true, D26B_NOW);
    assert!(starred.refreshing);
    assert!(starred.error.is_none());
    server.ok();
    let result = running.await.unwrap();
    assert!(!result.refreshing);
    assert!(result.error.is_none());
    assert!(result.starred[0].read);
    engine.shutdown();
    let reopened = d26b_open(dir.path());
    assert!(reopened.snapshot().starred[0].read);
}

#[test]
fn d26b_invalid_saved_copy_is_read_only_and_cache_flags_are_ignored() {
    let dir = tempfile::tempdir().unwrap();
    d26b_seed(dir.path());
    let engine = d26b_open(dir.path());
    let item = engine.snapshot().items[0].clone();
    engine.shutdown();
    for (field, value) in [
        ("title", serde_json::json!("")),
        ("url", serde_json::json!("javascript:bad")),
        ("first_seen_ms", serde_json::json!(0)),
        ("also_in", serde_json::json!(["openai"])),
    ] {
        let mut bad = serde_json::to_value(&item).unwrap();
        bad[field] = value;
        let bytes = serde_json::to_vec(&serde_json::json!({"version":1, "read":{}, "starred":{item.id.clone(): {"starred_at_ms":1,"item":bad}}})).unwrap();
        std::fs::write(dir.path().join("news-state.json"), &bytes).unwrap();
        let engine = d26b_open(dir.path());
        assert_eq!(engine.snapshot().items.len(), 1);
        assert_eq!(engine.snapshot().state_error.unwrap().kind, "cache");
        assert!(engine
            .set_read(vec![item.id.clone()], true, D26B_NOW)
            .state_error
            .is_some());
        assert_eq!(
            std::fs::read(dir.path().join("news-state.json")).unwrap(),
            bytes
        );
        engine.shutdown();
    }
    let mut cache = old_v2_cache();
    cache["sources"]["openai"]["items"][0]["read"] = true.into();
    cache["sources"]["openai"]["items"][0]["starred"] = true.into();
    std::fs::write(
        dir.path().join("news-cache.json"),
        serde_json::to_vec(&cache).unwrap(),
    )
    .unwrap();
    let engine = d26b_open(dir.path());
    assert!(!engine.snapshot().items[0].read);
    assert!(!engine.snapshot().items[0].starred);
}

#[test]
fn d26a_old_v2_fills_fields_without_writing_and_roundtrips() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let mut json = old_v2_cache();
    json["sources"]["openai"]["items"][0]["published_at"] = "1970-01-01T00:00:00.100Z".into();
    let bytes = serde_json::to_vec(&json).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    let cache = load_cache(&path, &crate::sources::registry(), 1794000000000).unwrap();
    let item = serde_json::to_value(&cache.sources["openai"].items[0]).unwrap();
    assert_eq!(item["first_seen_ms"], 100);
    assert_eq!(item["ai_summary"], false);
    assert_eq!(item["origin"], serde_json::Value::Null);
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    save_cache(&path, &cache).unwrap();
    let reopened = load_cache(&path, &crate::sources::registry(), 1794000000000).unwrap();
    assert_eq!(
        reopened.sources["openai"].items,
        cache.sources["openai"].items
    );
    assert_eq!(reopened.version, 2);
}

#[test]
fn d26a_old_v2_first_seen_fallback_matrix_uses_fixed_clock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    for (published, success, expected) in [
        (Some("1970-01-01T00:00:00.100Z"), Some(123), 100),
        (Some("1970-01-01T00:00:01Z"), Some(123), 123),
        (Some("1970-01-01T00:00:00.100Z"), None, 100),
        (None, Some(123), 123),
        (None, None, 999),
    ] {
        let mut json = old_v2_cache();
        json["sources"]["openai"]["last_success_ms"] = serde_json::json!(success);
        json["sources"]["openai"]["items"][0]["published_at"] = serde_json::json!(published);
        std::fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
        let cache = load_cache(&path, &crate::sources::registry(), 999).unwrap();
        assert_eq!(cache.sources["openai"].items[0].first_seen_ms, expected);
    }
}

#[test]
fn d26a_successful_commit_writes_back_other_sources_legacy_fields() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let bytes = serde_json::to_vec(&old_v2_cache()).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    engine.inner.state.lock().unwrap().active = Some((1, CancellationToken::new()));
    // An empty result is still a successful source commit.
    engine.inner.commit(1, 1, Ok(Vec::new()), 1794000000000);
    let stored: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(stored["version"], 2);
    assert_eq!(
        stored["sources"]["openai"]["items"][0]["first_seen_ms"],
        123
    );
    assert_eq!(stored["sources"]["openai"]["items"][0]["ai_summary"], false);
    assert_eq!(
        stored["sources"]["openai"]["items"][0]["origin"],
        serde_json::Value::Null
    );
    let reopened = load_cache(&path, &crate::sources::registry(), 1794000000100).unwrap();
    assert_eq!(
        reopened.sources["openai"].items,
        engine.inner.state.lock().unwrap().cache.sources["openai"].items
    );
}

#[test]
fn d26a_invalid_cached_new_fields_are_cache_errors() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    for (field, value) in [
        ("first_seen_ms", serde_json::json!(0)),
        ("first_seen_ms", serde_json::json!(-1)),
        ("first_seen_ms", serde_json::Value::Null),
        ("first_seen_ms", serde_json::json!("123")),
        ("ai_summary", serde_json::json!("true")),
        ("ai_summary", serde_json::Value::Null),
        ("origin", serde_json::json!("x".repeat(121))),
        ("origin", serde_json::json!("bad\u{1}origin")),
        ("origin", serde_json::json!("")),
        ("origin", serde_json::json!(123)),
    ] {
        let mut json = old_v2_cache();
        json["sources"]["openai"]["items"][0][field] = value;
        let bytes = serde_json::to_vec(&json).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(
            load_cache(&path, &crate::sources::registry(), 999)
                .err()
                .unwrap()
                .kind,
            "cache",
            "{field}"
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
}

#[test]
fn d26a_non_aihot_summary_flag_is_corrupt_cache() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let mut json = old_v2_cache();
    json["sources"]["openai"]["items"][0]["ai_summary"] = true.into();
    let bytes = serde_json::to_vec(&json).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    assert_eq!(
        engine.snapshot().error.as_ref().map(|e| e.kind.as_str()),
        Some("cache")
    );
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[test]
fn d26a_origin_normalises_as_literal_text() {
    let mut item = raw("one", "https://example.com/one", None);
    item.origin = Some("  <Publisher>\n News\u{1} &amp;  ".into());
    let items = normalise_items(
        "aihot",
        vec![item],
        true,
        Category::Chinese,
        ItemKind::General,
        true,
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(&items[0]).unwrap()["origin"],
        "<Publisher> News &amp;"
    );
    assert!(items[0].ai_summary);
    for (origin, expected) in [
        ("字".repeat(121), Some("字".repeat(120))),
        ("\n\t\u{1} ".into(), None),
    ] {
        let mut item = raw("origin", "https://example.com/origin", None);
        item.origin = Some(origin);
        let items = normalise_items(
            "aihot",
            vec![item],
            true,
            Category::Chinese,
            ItemKind::General,
            true,
        )
        .unwrap();
        assert_eq!(items[0].origin, expected);
    }
}

#[test]
fn d26a_aihot_model_kind_and_limits_survive_normalisation() {
    let source = crate::sources::aihot::Aihot;
    let body =
        include_str!("../sources/fixtures/aihot/model.xml").replace("Summary", &"字".repeat(4001));
    let parsed = source.parse(body.as_bytes()).unwrap();
    let items = normalise_items(
        &source.info().id,
        parsed,
        source.text_is_html(),
        source.info().category,
        source.default_kind(),
        source.ai_summary(),
    )
    .unwrap();
    assert_eq!(items[0].kind, "model");
    assert!(items[0].ai_summary);
    assert_eq!(items[0].title, "Title & text");
    assert_eq!(items[0].description.as_ref().unwrap().chars().count(), 4000);
    assert!(!items[0].description.as_ref().unwrap().contains("via AIHOT"));
    assert_eq!(items[0].origin.as_deref(), Some("Publisher：News"));
    assert_eq!(items[0].popularity, None);
}

#[test]
fn d26a_previously_empty_source_uses_refresh_time_for_new_items() {
    let mut items = normalise_items(
        "openai",
        vec![raw(
            "one",
            "https://example.com/one",
            Some("1970-01-01T00:00:00.100Z"),
        )],
        true,
        Category::Official,
        ItemKind::General,
        false,
    )
    .unwrap();
    let previous = SourceCache {
        items: Vec::new(),
        last_success_ms: Some(123),
    };
    stamp_first_seen(&mut items, Some(&previous), 999);
    assert_eq!(items[0].first_seen_ms, 999);
}

#[test]
fn d26a_snapshot_sorts_by_seen_then_date_then_registry() {
    let dir = tempfile::tempdir().unwrap();
    let entry = |source: &str, id: &str, seen: i64, date: Option<&str>| {
        serde_json::json!({
            "id": format!("{source}:{id}"), "source_id": source, "title": id,
            "url": format!("https://example.com/{source}/{id}"), "published_at": date,
            "description": null, "popularity_kind": null, "popularity": null,
            "also_in": [], "first_seen_ms": seen
        })
    };
    let json = serde_json::json!({"version":2,"disabled":[],"sources":{
        "openai":{"last_success_ms":400,"items":[
            entry("openai","old-seen-new-date",100,Some("2026-11-10T00:00:00Z")),
            entry("openai","new-seen",300,None),
            entry("openai","same-seen-dated",200,Some("2026-11-05T00:00:00Z")),
            entry("openai","same-seen-undated",200,None)]},
        "deepmind":{"last_success_ms":400,"items":[
            entry("deepmind","tie",200,Some("2026-11-05T00:00:00Z"))]}
    }});
    std::fs::write(
        dir.path().join("news-cache.json"),
        serde_json::to_vec(&json).unwrap(),
    )
    .unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    assert_eq!(
        engine
            .snapshot()
            .items
            .iter()
            .map(|i| i.id.clone())
            .collect::<Vec<_>>(),
        [
            "openai:new-seen",
            "openai:same-seen-dated",
            "deepmind:tie",
            "openai:same-seen-undated",
            "openai:old-seen-new-date"
        ]
    );
}

#[test]
fn d26a_first_seen_first_refresh_new_and_existing_items() {
    for initial in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        if initial {
            let mut cache = old_v2_cache();
            let mut kept = cache["sources"]["openai"]["items"][0].clone();
            kept["id"] = "openai:one".into();
            kept["first_seen_ms"] = 42.into();
            cache["sources"]["openai"]["items"] = serde_json::json!([kept]);
            std::fs::write(
                dir.path().join("news-cache.json"),
                serde_json::to_vec(&cache).unwrap(),
            )
            .unwrap();
        }
        let engine = NewsEngine::new(
            dir.path(),
            vec![Box::new(RssSource::new(
                "openai",
                "OpenAI",
                Category::Official,
                "https://example.com/",
                "https://example.invalid/",
            ))],
            D26B_NOW,
        )
        .unwrap();
        let now_ms = 1794000000000;
        engine.inner.state.lock().unwrap().active = Some((1, CancellationToken::new()));
        let body = br#"<rss version="2.0"><channel><title>Test</title><link>https://example.com</link><description>Test</description>
            <item><guid>one</guid><title>One</title><link>https://example.com/one</link><pubDate>Wed, 04 Nov 2026 00:00:00 GMT</pubDate></item>
            <item><guid>two</guid><title>Two</title><link>https://example.com/two</link><pubDate>Thu, 05 Nov 2026 00:00:00 GMT</pubDate></item>
            <item><guid>undated</guid><title>Undated</title><link>https://example.com/undated</link></item>
            <item><guid>future</guid><title>Future</title><link>https://example.com/future</link><pubDate>Fri, 01 Jan 2100 00:00:00 GMT</pubDate></item>
            </channel></rss>"#;
        let parsed = engine.inner.sources[0].parse(body).unwrap();
        let items = normalise_items(
            "openai",
            parsed,
            true,
            Category::Official,
            ItemKind::General,
            false,
        )
        .unwrap();
        engine.inner.commit(1, 0, Ok(items), now_ms);
        let snapshot = engine.snapshot();
        assert!(snapshot.error.is_none());
        assert_eq!(snapshot.items.len(), 4);
        let values = snapshot
            .items
            .iter()
            .map(|i| (i.id.clone(), serde_json::to_value(i).unwrap()))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(
            values["openai:one"]["first_seen_ms"],
            if initial { 42 } else { 1793750400000_i64 }
        );
        if initial {
            assert_eq!(values["openai:two"]["first_seen_ms"], now_ms);
        } else {
            assert_eq!(values["openai:two"]["first_seen_ms"], 1793836800000_i64);
        }
        for id in ["openai:undated", "openai:future"] {
            assert_eq!(values[id]["first_seen_ms"], now_ms);
        }
    }
}

#[test]
fn d26a_aihot_ranks_after_community_and_merges_earliest_seen() {
    let dir = tempfile::tempdir().unwrap();
    let mut cache = old_v2_cache();
    let entry = |id: &str, seen: i64| {
        serde_json::json!({
            "items": [{"id": format!("{id}:same"), "source_id": id, "title": id,
            "url": "https://example.com/shared", "published_at": null,
            "description": null, "popularity_kind": null, "popularity": null,
            "also_in": [], "first_seen_ms": seen}], "last_success_ms": 300
        })
    };
    cache["sources"] =
        serde_json::json!({"aihot": entry("aihot", 100), "hn-ai": entry("hn-ai", 200)});
    std::fs::write(
        dir.path().join("news-cache.json"),
        serde_json::to_vec(&cache).unwrap(),
    )
    .unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.items.len(), 1);
    assert_eq!(snapshot.items[0].source_id, "hn-ai");
    assert_eq!(snapshot.items[0].also_in, ["aihot"]);
    assert_eq!(
        serde_json::to_value(&snapshot.items[0]).unwrap()["first_seen_ms"],
        100
    );
    for category in ["official", "chinese", "tools", "community"] {
        let mut state = engine.inner.state.lock().unwrap();
        state
            .sources
            .iter_mut()
            .find(|s| s.id == "aihot")
            .unwrap()
            .category = category.into();
        let snapshot = assemble(&state);
        assert_eq!(snapshot.items[0].source_id, "hn-ai");
        assert_eq!(snapshot.items[0].first_seen_ms, 100);
        assert_eq!(state.cache.sources["hn-ai"].items[0].first_seen_ms, 200);
    }
}

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
    tokio::spawn(async move { engine.refresh(ids, D26B_NOW).await })
}

// A real chunked response keeps transport read deadlines separate from the total deadline.
async fn d26e_stream(interval: Duration, chunks: usize) -> Server {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/feed", listener.local_addr().unwrap());
    let (seen_tx, seen) = oneshot::channel();
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
        let header = b"HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
        if socket.write_all(header).await.is_err() {
            return;
        }
        for part in FEED.chunks(FEED.len().div_ceil(chunks)) {
            let frame = format!("{:x}\r\n", part.len());
            if socket.write_all(frame.as_bytes()).await.is_err()
                || socket.write_all(part).await.is_err()
                || socket.write_all(b"\r\n").await.is_err()
            {
                return;
            }
            tokio::time::sleep(interval).await;
        }
        let _ = socket.write_all(b"0\r\n\r\n").await;
    });
    Server {
        url,
        seen,
        reply: None,
        task,
    }
}

#[tokio::test]
async fn d26e_read_timeout_is_recognized_by_reqwest_and_http_error() {
    let server = d26e_stream(Duration::from_secs(3), 2).await;
    let http = Client::builder()
        .read_timeout(Duration::from_millis(400))
        .timeout(Duration::from_millis(1200))
        .build()
        .unwrap();
    let mut response = http.get(&server.url).send().await.unwrap();
    assert!(response.chunk().await.unwrap().is_some());
    let err = response.chunk().await.unwrap_err();
    assert!(
        err.is_timeout(),
        "read timeout must retain its timeout category: {err}"
    );
    assert_eq!(http_error(err).kind, "timeout");
}

#[tokio::test]
async fn d26e_slow_chunks_succeed_beyond_old_total_timeout() {
    let server = d26e_stream(Duration::from_millis(100), 8).await;
    let dir = tempfile::tempdir().unwrap();
    let engine = NewsEngine::open(
        dir.path(),
        vec![source("slow", Category::Official, &server)],
        RequestTimeouts {
            connect: Duration::from_millis(200),
            read: Duration::from_millis(400),
            total: Duration::from_millis(1200),
        },
        D26B_NOW,
    )
    .unwrap();
    let result = engine.refresh(None, D26B_NOW).await;
    assert!(
        result.sources[0].error.is_none(),
        "{:?}",
        result.sources[0].error
    );
    assert!(!result.items.is_empty());
}

#[tokio::test]
async fn d26e_stalled_body_times_out_before_total_deadline() {
    let server = d26e_stream(Duration::from_secs(3), 2).await;
    let dir = tempfile::tempdir().unwrap();
    let engine = NewsEngine::open(
        dir.path(),
        vec![source("stall", Category::Official, &server)],
        RequestTimeouts {
            connect: Duration::from_millis(200),
            read: Duration::from_millis(400),
            total: Duration::from_millis(1200),
        },
        D26B_NOW,
    )
    .unwrap();
    let result = tokio::time::timeout(Duration::from_millis(800), engine.refresh(None, D26B_NOW))
        .await
        .expect("read timeout must fire before total timeout");
    assert_eq!(result.sources[0].error.as_ref().unwrap().kind, "timeout");
}

#[tokio::test]
async fn d26e_continuous_chunks_still_obey_total_deadline() {
    let server = d26e_stream(Duration::from_millis(100), 30).await;
    let dir = tempfile::tempdir().unwrap();
    let engine = NewsEngine::open(
        dir.path(),
        vec![source("total", Category::Official, &server)],
        RequestTimeouts {
            connect: Duration::from_millis(200),
            read: Duration::from_millis(400),
            total: Duration::from_millis(1200),
        },
        D26B_NOW,
    )
    .unwrap();
    let result = tokio::time::timeout(Duration::from_millis(2000), engine.refresh(None, D26B_NOW))
        .await
        .unwrap();
    assert_eq!(result.sources[0].error.as_ref().unwrap().kind, "timeout");
    assert!(result.items.is_empty());
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
        let engine = NewsEngine::new(directory.path(), vec![feed], D26B_NOW).unwrap();
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
            let engine = NewsEngine::new(dir.path(), vec![feed], D26B_NOW).unwrap();
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
                    load_cache(&dir.path().join("news-cache.json"), &[], 1794000000000)
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
    let engine = NewsEngine::new(dir.path(), sources, D26B_NOW).unwrap();
    let running = start(&engine, None);
    for s in &mut servers[..4] {
        s.requested().await;
    }
    servers[4].not_requested();
    servers[5].not_requested();
    assert!(engine.snapshot().sources.iter().all(|s| s.refreshing));
    assert_eq!(
        engine.refresh(None, D26B_NOW).await.error.unwrap().kind,
        "busy"
    );
    servers[0].ok();
    servers[4].requested().await;
    let snapshot = engine.snapshot();
    assert!(snapshot.sources[0].last_success_ms.is_some());
    assert!(!snapshot.sources[0].refreshing);
    let disk = load_cache(&dir.path().join("news-cache.json"), &[], 1794000000000).unwrap();
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
        load_cache(&dir.path().join("news-cache.json"), &[], 1794000000000)
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
    let mut old_items = normalise_items(
        "b",
        vec![raw("kept", "https://example.com/old-b", None)],
        true,
        Category::Official,
        ItemKind::General,
        false,
    )
    .unwrap();
    stamp_first_seen(&mut old_items, None, 55);
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
        D26B_NOW,
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
        load_cache(&dir.path().join("news-cache.json"), &[], 1794000000000)
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
        D26B_NOW,
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
    assert!(!engine.refresh(Some(vec![]), D26B_NOW).await.refreshing);
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
        D26B_NOW,
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
        D26B_NOW,
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
    let reopened = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
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
        let engine = NewsEngine::new(
            dir.path(),
            vec![source(id, Category::Official, &server)],
            D26B_NOW,
        )
        .unwrap();
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
        D26B_NOW,
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
        D26B_NOW,
    )
    .unwrap();
    assert!(!engine.snapshot().sources[0].enabled);
    assert!(engine.refresh(None, D26B_NOW).await.items.is_empty());
    assert_eq!(engine.set_source_enabled("openai", true).items, before);
    engine.shutdown();
    let reopened = NewsEngine::new(
        dir.path(),
        vec![source("openai", Category::Official, &server)],
        D26B_NOW,
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
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.items[0].id, "openai:old");
    assert_eq!(snapshot.items[0].source_id, "openai");
    assert_eq!(snapshot.items[0].title, "A <literal>");
    assert_eq!(
        serde_json::to_value(&snapshot.items[0]).unwrap()["kind"],
        "general"
    );
    assert_eq!(snapshot.sources[0].last_success_ms, Some(123));
    assert_eq!(std::fs::read(&path).unwrap(), legacy);
    engine.set_source_enabled("qbitai", false);
    assert_eq!(load_cache(&path, &[], 1794000000000).unwrap().version, 2);
    engine.shutdown();
    for invalid in [
        br#"{"version":99}"#.as_slice(),
        br#"{"version":2,"sources":{},"disabled":"no"}"#.as_slice(),
    ] {
        std::fs::write(&path, invalid).unwrap();
        let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
        assert_eq!(engine.snapshot().error.unwrap().kind, "cache");
        assert_eq!(std::fs::read(&path).unwrap(), invalid);
        engine.shutdown();
    }
}

fn raw(id: &str, url: &str, date: Option<&str>) -> RawItem {
    RawItem {
        origin: None,
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

fn old_v2_cache() -> serde_json::Value {
    let entry = |id: &str| {
        serde_json::json!({
            "items": [{"id": format!("{id}:old"), "source_id": id,
                "title": "Deprecated pricing", "url": "https://example.com/old",
                "published_at": null, "description": null,
                "popularity_kind": null, "popularity": null, "also_in": []}],
            "last_success_ms": 123
        })
    };
    serde_json::json!({"version": 2, "disabled": [], "sources": {
        "openai": entry("openai"),
        "gh-release:openai/codex": entry("gh-release:openai/codex")
    }})
}

fn normalised_kind(
    title: &str,
    category: Category,
    structured: Option<ItemKind>,
    default: ItemKind,
) -> String {
    let mut item = raw("kind", "https://example.com/kind", None);
    item.title = title.into();
    item.description = Some("deprecated pricing 弃用 定价".into());
    item.kind = structured;
    normalise_items("kind", vec![item], true, category, default, false)
        .unwrap()
        .remove(0)
        .kind
}

#[test]
fn d25_r4_english_keyword_boundaries_allow_adjacent_chinese() {
    for category in [Category::Official, Category::Tools] {
        for (title, expected) in [
            ("priceless", "general"),
            ("price_v2", "general"),
            ("price2", "general"),
            ("xprice", "general"),
            ("price调整", "pricing"),
            ("API price下调", "pricing"),
            ("调整price", "pricing"),
        ] {
            assert_eq!(
                normalised_kind(title, category, None, ItemKind::General),
                expected,
                "{title}"
            );
        }
    }
}

#[test]
fn d25_keywords_match_contract_in_official_and_tools_titles() {
    for category in [Category::Official, Category::Tools] {
        for title in [
            "deprecate",
            "deprecated",
            "deprecation",
            "retire",
            "retired",
            "retirement",
            "retiring",
            "shut down",
            "shutdown",
            "sunset",
            "end of life",
            "弃用",
            "下线",
            "停用",
            "退役",
        ] {
            assert_eq!(
                normalised_kind(
                    &format!("Update: {}!", title.to_uppercase()),
                    category,
                    None,
                    ItemKind::General
                ),
                "deprecation",
                "{title}"
            );
        }
        for title in [
            "price", "prices", "pricing", "priced", "价格", "定价", "降价", "涨价", "计费",
        ] {
            assert_eq!(
                normalised_kind(
                    &format!("Update: {}!", title.to_uppercase()),
                    category,
                    None,
                    ItemKind::General
                ),
                "pricing",
                "{title}"
            );
        }
        assert_eq!(
            normalised_kind(
                "PRICING sunset",
                category,
                Some(ItemKind::Model),
                ItemKind::Release
            ),
            "deprecation"
        );
        assert_eq!(
            normalised_kind("定价并下线", category, None, ItemKind::General),
            "deprecation"
        );
    }
}

#[test]
fn d25_keywords_respect_boundaries_categories_and_normalised_title_only() {
    for title in [
        "priceless",
        "overpriced",
        "prices_v2",
        "xshutdown",
        "sunsetting",
        "New model",
        "<script>deprecated</script>Update",
        "Update",
    ] {
        assert_eq!(
            normalised_kind(title, Category::Official, None, ItemKind::General),
            "general",
            "{title}"
        );
    }
    for category in [Category::Community, Category::Chinese] {
        assert_eq!(
            normalised_kind(
                "deprecated pricing 弃用 定价",
                category,
                None,
                ItemKind::General
            ),
            "general"
        );
        assert_eq!(
            normalised_kind(
                "deprecated pricing",
                category,
                Some(ItemKind::Model),
                ItemKind::Release
            ),
            "model"
        );
    }
    for (title, expected) in [
        ("shutdown", "deprecation"),
        ("<b>SHUT</b>\n down", "deprecation"),
        ("Price &amp; details", "pricing"),
        ("版本降价了", "pricing"),
    ] {
        assert_eq!(
            normalised_kind(title, Category::Official, None, ItemKind::General),
            expected
        );
    }
    assert_eq!(
        normalised_kind(
            &format!("{} pricing", "a".repeat(512)),
            Category::Official,
            None,
            ItemKind::General
        ),
        "general"
    );
}

#[test]
fn d25_kind_precedence_is_keyword_then_structure_then_source_default() {
    assert_eq!(
        normalised_kind(
            "Model update",
            Category::Official,
            Some(ItemKind::Model),
            ItemKind::Release
        ),
        "model"
    );
    assert_eq!(
        normalised_kind(
            "Pricing update",
            Category::Official,
            Some(ItemKind::Model),
            ItemKind::Release
        ),
        "pricing"
    );
    for kind in [
        ItemKind::Release,
        ItemKind::Api,
        ItemKind::Deprecation,
        ItemKind::Pricing,
        ItemKind::Model,
        ItemKind::General,
    ] {
        assert_eq!(
            normalised_kind("Update", Category::Official, None, kind),
            kind.as_str()
        );
        assert_eq!(
            normalised_kind("Update", Category::Official, Some(kind), ItemKind::Release),
            kind.as_str()
        );
    }
}

#[test]
fn d25_all_valid_cache_kinds_survive_roundtrip_without_reclassification() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    for kind in [
        "release",
        "api",
        "deprecation",
        "pricing",
        "model",
        "general",
    ] {
        let mut json = old_v2_cache();
        json["sources"]["openai"]["items"][0]["kind"] = kind.into();
        std::fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
        let cache = load_cache(&path, &crate::sources::registry(), 1794000000000).unwrap();
        assert_eq!(cache.sources["openai"].items[0].kind, kind);
        save_cache(&path, &cache).unwrap();
        assert_eq!(
            load_cache(&path, &crate::sources::registry(), 1794000000000)
                .unwrap()
                .sources["openai"]
                .items[0]
                .kind,
            kind
        );
    }
}

#[test]
fn d25_old_v2_cache_uses_source_defaults_without_reclassification_or_disk_write() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    let bytes = serde_json::to_vec(&old_v2_cache()).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
    assert!(engine.snapshot().error.is_none());
    let state = engine.inner.state.lock().unwrap();
    for (id, expected) in [
        ("openai", "general"),
        ("gh-release:openai/codex", "release"),
    ] {
        assert_eq!(
            serde_json::to_value(&state.cache.sources[id].items[0]).unwrap()["kind"],
            expected
        );
    }
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[test]
fn d25_invalid_cache_kinds_are_visible_and_preserve_disk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("news-cache.json");
    for invalid in [
        serde_json::json!("unknown"),
        serde_json::json!(""),
        serde_json::json!("Release"),
        serde_json::Value::Null,
        serde_json::json!(12),
    ] {
        let mut cache = old_v2_cache();
        cache["sources"]["openai"]["items"][0]["kind"] = invalid;
        let bytes = serde_json::to_vec(&cache).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        let engine = NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
        assert_eq!(engine.snapshot().error.unwrap().kind, "cache");
        assert!(engine.snapshot().items.is_empty());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        engine.shutdown();
    }
}

#[test]
fn d25_same_source_urls_survive_and_cross_source_duplicates_join_first_sorted_item() {
    let dir = tempfile::tempdir().unwrap();
    let sources = ["openai", "deepmind"].map(|id| {
        Box::new(RssSource::new(
            id,
            id,
            Category::Official,
            "https://example.com/",
            "https://example.invalid/",
        )) as Box<dyn Source>
    });
    let engine = NewsEngine::new(dir.path(), sources.into(), D26B_NOW).unwrap();
    {
        let mut state = engine.inner.state.lock().unwrap();
        for id in ["openai", "deepmind"] {
            let mut items = normalise_items(
                id,
                vec![
                    raw(
                        "older",
                        "https://example.com/shared",
                        Some("2026-11-04T00:00:00Z"),
                    ),
                    raw(
                        "newer",
                        "https://example.com/shared/?utm_source=test#top",
                        Some("2026-11-05T00:00:00Z"),
                    ),
                ],
                true,
                Category::Official,
                ItemKind::General,
                false,
            )
            .unwrap();
            // A valid cache need not arrive in display order.
            items.reverse();
            state.cache.sources.insert(
                id.into(),
                SourceCache {
                    items,
                    last_success_ms: Some(1),
                },
            );
        }
    }
    let snapshot = engine.snapshot();
    assert_eq!(
        snapshot
            .items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["openai:newer", "openai:older"]
    );
    assert_eq!(snapshot.items[0].also_in, ["deepmind"]);
    assert!(snapshot.items[1].also_in.is_empty());
    let state = engine.inner.state.lock().unwrap();
    assert!(state
        .cache
        .sources
        .values()
        .all(|source| source.items.len() == 2
            && source.items.iter().all(|item| item.also_in.is_empty())));
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
    let items = normalise_items(
        &source.info().id,
        raw,
        source.text_is_html(),
        source.info().category,
        source.default_kind(),
        source.ai_summary(),
    )
    .unwrap();
    assert_eq!(
        items[0].description.as_deref(),
        Some("Supports Vec<String> now.")
    );
    assert_eq!(items[0].kind, "release");
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
    let items = normalise_items(
        &source.info().id,
        raw,
        source.text_is_html(),
        source.info().category,
        source.default_kind(),
        source.ai_summary(),
    )
    .unwrap();
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
    let items = normalise_items(
        &source.info().id,
        raw,
        source.text_is_html(),
        source.info().category,
        source.default_kind(),
        source.ai_summary(),
    )
    .unwrap();
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
            source.info().category,
            source.default_kind(),
            source.ai_summary(),
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
    let items = normalise_items(
        "source",
        input,
        true,
        Category::Official,
        ItemKind::General,
        false,
    )
    .unwrap();
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
        Category::Official,
        ItemKind::General,
        false,
    )
    .unwrap();
    assert_eq!(duplicates.len(), 1);
    assert_eq!(duplicates[0].id, "s:same");
    assert_eq!(
        normalise_items(
            "s",
            vec![raw("bad", "file:///bad", None)],
            true,
            Category::Official,
            ItemKind::General,
            false
        )
        .unwrap_err()
        .kind,
        "parse"
    );
    assert!(normalise_items(
        "s",
        vec![],
        true,
        Category::Official,
        ItemKind::General,
        false
    )
    .unwrap()
    .is_empty());
}

#[test]
fn normalised_text_can_always_be_reloaded_from_cache() {
    let dir = tempfile::tempdir().unwrap();
    let mut item = raw("controls", "https://example.com/controls", None);
    item.title = "Title\u{1} text".into();
    item.description = Some("Description\u{7}".into());
    let mut cache = Cache {
        sources: BTreeMap::from([(
            "s".into(),
            SourceCache {
                items: normalise_items(
                    "s",
                    vec![item],
                    true,
                    Category::Official,
                    ItemKind::General,
                    false,
                )
                .unwrap(),
                last_success_ms: Some(1),
            },
        )]),
        ..Cache::default()
    };
    let path = dir.path().join("news-cache.json");
    stamp_first_seen(&mut cache.sources.get_mut("s").unwrap().items, None, 1);
    save_cache(&path, &cache).unwrap();
    assert!(load_cache(&path, &[], 1794000000000).is_ok());
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
        D26B_NOW,
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
                Category::Official,
                ItemKind::General,
                false,
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
                Category::Official,
                ItemKind::General,
                false,
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
            D26B_NOW,
        )
        .unwrap();
        let running = start(&engine, None);
        server.requested().await;
        if shutdown {
            engine.shutdown();
            engine.shutdown();
            server.ok();
            assert_eq!(running.await.unwrap().error.unwrap().kind, "closed");
            assert_eq!(
                engine.refresh(None, D26B_NOW).await.error.unwrap().kind,
                "closed"
            );
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
        let replacement =
            NewsEngine::new(dir.path(), crate::sources::registry(), D26B_NOW).unwrap();
        assert!(replacement.snapshot().items.is_empty());
        assert!(!dir.path().join("news-cache.json").exists());
    }
}
