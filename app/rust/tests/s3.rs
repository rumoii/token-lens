use rust_lib_token_lens::api::stats::{StatsClient, StatsFilter, StatsRequestQuery};
use std::{
    fs,
    path::Path,
    thread,
    time::{Duration, Instant},
};

const CLAUDE: &str = r#"{"sessionId":"s3","timestamp":"2026-01-15T12:00:00Z","message":{"id":"s3","usage":{"input_tokens":17}}}"#;

fn fixture(home: &Path) {
    let path = home.join(".claude/projects/project/usage.jsonl");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, CLAUDE).unwrap();
}

#[test]
fn s3_preview_discovers_all_tools_and_counts_matching_files() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    fixture(&home);
    fs::write(home.join(".codex"), "not a directory").unwrap();
    let client = StatsClient::new(
        root.path().join("data").display().to_string(),
        Some(home.display().to_string()),
    )
    .unwrap();
    let discovery = client.discovery(true).unwrap();
    assert_eq!(discovery.tools.len(), 28);
    assert!(discovery
        .tools
        .iter()
        .flat_map(|tool| &tool.directories)
        .all(|dir| Path::new(&dir.path).starts_with(&home)));
    let claude = discovery
        .tools
        .iter()
        .find(|tool| tool.source == "claude")
        .unwrap();
    assert_eq!(claude.status, "found");
    assert_eq!(claude.directories[0].files, 1);
    assert_eq!(claude.directories[0].status, "found");
    assert_eq!(
        discovery
            .tools
            .iter()
            .find(|tool| tool.source == "codex")
            .unwrap()
            .status,
        "io_error"
    );
    assert_eq!(
        discovery
            .tools
            .iter()
            .find(|tool| tool.source == "qwen")
            .unwrap()
            .status,
        "missing"
    );
}

#[test]
fn s3_exclusion_cannot_be_overridden_by_an_explicit_source() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    fixture(&home);
    let client = StatsClient::new(
        root.path().join("data").display().to_string(),
        Some(home.display().to_string()),
    )
    .unwrap();
    client.sync().unwrap();
    assert!(client.sync_progress().is_none());
    assert_eq!(
        client
            .summary(StatsFilter::default(), 0)
            .unwrap()
            .totals
            .gross_tokens,
        17
    );
    let filter = StatsFilter {
        source: Some("claude".into()),
        exclude_sources: Some(vec!["claude".into()]),
        ..Default::default()
    };
    assert_eq!(client.summary(filter, 0).unwrap().totals.gross_tokens, 0);
}

#[test]
fn every_stats_query_excludes_the_same_source() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    fixture(&home);
    let qwen = home.join(".qwen/usage/s3-usage-01.jsonl");
    fs::create_dir_all(qwen.parent().unwrap()).unwrap();
    fs::write(
        qwen,
        r#"{"id":"r","sessionId":"s3","timestamp":"2026-01-15T12:00:10Z","input_tokens":29}"#,
    )
    .unwrap();
    let client = StatsClient::new_with_fixed_clock(
        root.path().join("data").display().to_string(),
        Some(home.display().to_string()),
        1768564800000,
    )
    .unwrap();
    client.sync().unwrap();
    let all = StatsFilter::default();
    let hidden = StatsFilter {
        exclude_sources: Some(vec!["claude".into()]),
        ..Default::default()
    };
    let only_claude = StatsFilter {
        source: Some("claude".into()),
        ..Default::default()
    };
    let expected = 29;
    let totals = |filter: StatsFilter| client.summary(filter, 0).unwrap().totals.gross_tokens;
    assert_eq!(totals(all.clone()) - totals(only_claude), expected);
    assert_eq!(totals(hidden.clone()), expected);
    for by in ["source", "source_model", "project"] {
        let breakdown = client.breakdown(by.into(), hidden.clone(), 0).unwrap();
        assert_eq!(breakdown.totals.gross_tokens, expected);
        assert_eq!(
            breakdown
                .groups
                .iter()
                .map(|group| group.gross_tokens)
                .sum::<i64>(),
            expected
        );
    }
    let trend = client.timeseries("day".into(), hidden.clone(), 0).unwrap();
    assert_eq!(
        trend
            .points
            .iter()
            .map(|bucket| bucket.gross_tokens)
            .sum::<i64>()
            + trend.unallocated.map_or(0, |value| value.gross_tokens),
        expected
    );
    let matrix = client
        .matrix("day".into(), "source".into(), hidden.clone(), 0)
        .unwrap();
    assert_eq!(
        matrix
            .rows
            .iter()
            .map(|bucket| bucket.gross_tokens)
            .sum::<i64>()
            + matrix.unallocated.map_or(0, |value| value.gross_tokens),
        expected
    );
    let sessions = client.sessions(Some(20), None, hidden.clone(), 0).unwrap();
    assert_eq!(sessions.items.len(), 1);
    let qwen = &sessions.items[0];
    assert_eq!(qwen.gross_tokens, expected);
    let detail = |source, filter| {
        client
            .session_detail_in_period(source, "s3".into(), "day".into(), filter, 0)
            .unwrap()
    };
    assert_eq!(
        detail("qwen".into(), hidden.clone())
            .unwrap()
            .period
            .unwrap()
            .gross_tokens,
        expected
    );
    assert!(detail("claude".into(), hidden.clone()).is_none());
    let requests = StatsRequestQuery {
        source: None,
        session_id: None,
        bucket: None,
        timed_only: false,
        sort: "time".into(),
        descending: true,
        limit: 20,
        offset: 0,
        include_summary: true,
    };
    let result = client
        .requests(hidden.clone(), requests.clone(), 0)
        .unwrap();
    assert_eq!(result.total, Some(1));
    assert_eq!(result.items[0].input_tokens, Some(expected));
    let session_requests = StatsRequestQuery {
        source: Some("claude".into()),
        session_id: Some("s3".into()),
        ..requests
    };
    assert_eq!(
        client.requests(hidden, session_requests, 0).unwrap().total,
        Some(0)
    );
    let empty = StatsFilter {
        exclude_sources: Some(vec![]),
        ..Default::default()
    };
    assert_eq!(
        serde_json::to_vec(&client.summary(all, 0).unwrap()).unwrap(),
        serde_json::to_vec(&client.summary(empty, 0).unwrap()).unwrap()
    );
}

fn many_files(home: &Path) {
    let projects = home.join(".claude/projects/synthetic");
    fs::create_dir_all(&projects).unwrap();
    for index in 0..240 {
        fs::write(
            projects.join(format!("{index}.jsonl")),
            CLAUDE.replace("\"s3\"", &format!("\"s{index}\"")),
        )
        .unwrap();
    }
}

#[tokio::test]
async fn progress_is_monotonic_and_clears_on_success_failure_and_cancellation() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let data = root.path().join("data");
    many_files(&home);
    let client =
        StatsClient::new(data.display().to_string(), Some(home.display().to_string())).unwrap();
    for cancel in [false, true] {
        let worker = client.clone();
        let work = thread::spawn(move || worker.sync_triggered("reread".into()));
        let timeout = Instant::now() + Duration::from_secs(15);
        let (mut index, mut files, mut saw_discovering, mut saw_reading) = (0, 0, false, false);
        while !work.is_finished() {
            assert!(
                Instant::now() < timeout,
                "timed out waiting for synthetic sync progress"
            );
            if let Some(progress) = client.sync_progress() {
                assert_eq!(progress.trigger, "reread");
                assert_eq!(progress.total, 28);
                assert!(progress.index >= index && progress.files_read >= files);
                index = progress.index;
                files = progress.files_read;
                if progress.stage == "reading" {
                    saw_reading = true;
                    assert!(progress.source.is_some());
                    assert_eq!(progress.first_sync, Some(!cancel));
                    if cancel {
                        client.shutdown().await;
                        break;
                    }
                } else {
                    assert_eq!(progress.stage, "discovering");
                    assert!(!saw_reading);
                    saw_discovering = true;
                }
            }
            thread::yield_now();
        }
        let result = work.join().unwrap();
        assert!(saw_discovering && saw_reading);
        if cancel {
            assert_eq!(result.unwrap_err(), "cancelled");
        } else {
            assert!(files > 0);
            assert_eq!(result.unwrap().parsed_files, 240);
        }
        assert!(client.sync_progress().is_none());
    }
    let failure =
        StatsClient::new(data.display().to_string(), Some(home.display().to_string())).unwrap();
    fs::write(data.join("sync.lock"), "").unwrap();
    assert!(failure.sync().unwrap_err().starts_with("LEGACY_SYNC_LOCK:"));
    assert!(failure.sync_progress().is_none());
}
