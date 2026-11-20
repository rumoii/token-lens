//! Source module; see `super::Source` and docs/development/news.md.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;

use super::{Category, ParseError, Popularity, PopularityKind, RawItem, Source, SourceInfo};

const RELEASE_REPOSITORIES: [(&str, &str, Option<&str>); 6] = [
    ("anthropics/claude-code", "Claude Code", None),
    ("openai/codex", "Codex", Some("rust-v")),
    ("google-gemini/gemini-cli", "Gemini CLI", None),
    ("anomalyco/opencode", "OpenCode", Some("v")),
    ("earendil-works/pi", "Pi", None),
    ("ollama/ollama", "Ollama", None),
];

struct ReleaseSource {
    repo: &'static str,
    name: &'static str,
    tag_prefix: Option<&'static str>,
}

pub fn releases() -> Vec<Box<dyn Source>> {
    RELEASE_REPOSITORIES
        .iter()
        .map(|&(repo, name, tag_prefix)| {
            Box::new(ReleaseSource {
                repo,
                name,
                tag_prefix,
            }) as Box<dyn Source>
        })
        .collect()
}

impl Source for ReleaseSource {
    fn default_kind(&self) -> super::ItemKind {
        super::ItemKind::Release
    }

    fn text_is_html(&self) -> bool {
        false
    }

    fn max_body_bytes(&self) -> usize {
        16 * 1024 * 1024
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: format!("gh-release:{}", self.repo),
            name: self.name.to_owned(),
            category: Category::Tools,
            home_url: format!("https://github.com/{}", self.repo),
        }
    }

    fn url(&self, _now_ms: i64) -> String {
        format!(
            "https://api.github.com/repos/{}/releases?per_page=20",
            self.repo
        )
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let releases: Vec<GitHubRelease> = serde_json::from_slice(body)
            .map_err(|err| ParseError(format!("invalid GitHub releases response: {err}")))?;
        let mut saw_candidate = false;
        let mut items = Vec::new();
        for release in releases {
            if release.draft
                || release.prerelease
                || self.tag_prefix.is_some_and(|prefix| {
                    !release
                        .tag_name
                        .as_deref()
                        .is_some_and(|tag| tag.starts_with(prefix))
                })
            {
                continue;
            }
            saw_candidate = true;
            let title = release
                .name
                .filter(|name| !name.is_empty())
                .or(release.tag_name)
                .filter(|title| !title.is_empty());
            let (Some(id), Some(title), Some(url)) = (
                release.id,
                title,
                release.html_url.filter(|url| !url.is_empty()),
            ) else {
                continue;
            };
            items.push(RawItem {
                origin: None,
                kind: None,
                native_id: id.to_string(),
                title,
                url,
                published_at: parse_date(release.published_at),
                description: release_description(release.body.as_deref()),
                popularity: None,
            });
        }
        if saw_candidate && items.is_empty() {
            Err(ParseError(
                "GitHub releases contained no valid stable entries".to_owned(),
            ))
        } else {
            Ok(items)
        }
    }
}

#[derive(Deserialize)]
struct GitHubRelease {
    id: Option<u64>,
    name: Option<String>,
    tag_name: Option<String>,
    html_url: Option<String>,
    published_at: Option<String>,
    draft: bool,
    prerelease: bool,
    body: Option<String>,
}

fn remove_paired(text: &str, marker: &str) -> String {
    let mut remaining = text;
    let mut output = String::new();
    while let Some(start) = remaining.find(marker) {
        output.push_str(&remaining[..start]);
        let after = &remaining[start + marker.len()..];
        let Some(end) = after.find(marker) else {
            output.push_str(&remaining[start..]);
            return output;
        };
        output.push_str(&after[..end]);
        remaining = &after[end + marker.len()..];
    }
    output.push_str(remaining);
    output
}

fn release_description(body: Option<&str>) -> Option<String> {
    let mut lines = body?
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let after_hashes = line.trim_start_matches('#');
            let heading_level = line.len() - after_hashes.len();
            if (1..=6).contains(&heading_level)
                && (after_hashes.is_empty() || after_hashes.starts_with(' '))
            {
                return None;
            }
            Some(
                line.strip_prefix("* ")
                    .or_else(|| line.strip_prefix("- "))
                    .or_else(|| line.strip_prefix("+ "))
                    .unwrap_or(line),
            )
        })
        .collect::<Vec<_>>()
        .join(" ");
    for marker in ["**", "__", "`"] {
        lines = remove_paired(&lines, marker);
    }
    let mut remaining = lines.as_str();
    let mut text = String::new();
    while !remaining.is_empty() {
        let link = remaining.strip_prefix('!').unwrap_or(remaining);
        if let Some(label) = link.strip_prefix('[') {
            if let Some(end) = label.find("](") {
                let target = &label[end + 2..];
                let mut depth = 1;
                let close = target.char_indices().find_map(|(index, ch)| {
                    if ch == '(' {
                        depth += 1;
                    }
                    if ch == ')' {
                        depth -= 1;
                    }
                    (depth == 0).then_some(index)
                });
                if let Some(close) = close {
                    text.push_str(&label[..end]);
                    remaining = &target[close + 1..];
                    continue;
                }
            }
        }
        let url = remaining
            .strip_prefix('(')
            .or_else(|| remaining.strip_prefix('<'))
            .unwrap_or(remaining);
        if url.starts_with("https://") || url.starts_with("http://") || url.starts_with("www.") {
            remaining = &url[url.find(char::is_whitespace).unwrap_or(url.len())..];
            continue;
        }
        let ch = remaining.chars().next().unwrap();
        text.push(ch);
        remaining = &remaining[ch.len_utf8()..];
    }
    let text: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(300)
        .collect();
    (!text.is_empty()).then_some(text)
}

struct NewRepos;

pub fn new_repos() -> Box<dyn Source> {
    Box::new(NewRepos)
}

impl Source for NewRepos {
    fn text_is_html(&self) -> bool {
        false
    }

    fn info(&self) -> SourceInfo {
        SourceInfo {
            id: "github-new".to_owned(),
            name: "GitHub 新项目".to_owned(),
            category: Category::Community,
            home_url: "https://github.com".to_owned(),
        }
    }

    fn url(&self, now_ms: i64) -> String {
        let now =
            DateTime::from_timestamp_millis(now_ms).expect("now_ms must be a valid timestamp");
        let start = (now - chrono::Duration::days(7)).date_naive();
        format!(
            "https://api.github.com/search/repositories?q=created%3A%3E%3D{start}%20topic%3Allm%2Cai-agent%2Cgenerative-ai%2Cmachine-learning&sort=stars&order=desc&per_page=30"
        )
    }

    fn accepts(&self) -> &'static [&'static str] {
        &["application/json"]
    }

    fn parse(&self, body: &[u8]) -> Result<Vec<RawItem>, ParseError> {
        let response: SearchResponse = serde_json::from_slice(body).map_err(|err| {
            ParseError(format!("invalid GitHub repository search response: {err}"))
        })?;
        let had_entries = !response.items.is_empty();
        let items = response
            .items
            .into_iter()
            .filter_map(|repo| {
                let (Some(id), Some(title), Some(url)) = (
                    repo.id,
                    repo.full_name.filter(|name| !name.is_empty()),
                    repo.html_url.filter(|url| !url.is_empty()),
                ) else {
                    return None;
                };
                Some(RawItem {
                    origin: None,
                    kind: None,
                    native_id: id.to_string(),
                    title,
                    url,
                    published_at: parse_date(repo.created_at),
                    description: repo.description,
                    popularity: repo.stargazers_count.map(|value| Popularity {
                        kind: PopularityKind::Stars,
                        value,
                    }),
                })
            })
            .collect::<Vec<_>>();
        if had_entries && items.is_empty() {
            Err(ParseError(
                "GitHub repository search contained no valid entries".to_owned(),
            ))
        } else {
            Ok(items)
        }
    }
}

#[derive(Deserialize)]
struct SearchResponse {
    items: Vec<Repository>,
}

#[derive(Deserialize)]
struct Repository {
    id: Option<u64>,
    full_name: Option<String>,
    html_url: Option<String>,
    description: Option<String>,
    created_at: Option<String>,
    stargazers_count: Option<i64>,
}

fn parse_date(value: Option<String>) -> Option<String> {
    value
        .and_then(|value| DateTime::parse_from_rfc3339(&value).ok())
        .map(|value| {
            value
                .with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::AutoSi, true)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_descriptions_are_plain_short_text() {
        let items = release()
            .parse(include_bytes!("fixtures/github/releases.json"))
            .unwrap();
        assert_eq!(
            items[0].description.as_deref(),
            Some("Open the agent command center.")
        );
        let mut fixture: serde_json::Value =
            serde_json::from_slice(include_bytes!("fixtures/github/releases.json")).unwrap();
        fixture[0]["body"] = serde_json::json!("# Heading\n* **Bold** [release](https://example.com/a_(b))\n- __under__ `code`\n+ next https://example.com/raw\nhttps://example.com/only");
        let items = release()
            .parse(&serde_json::to_vec(&fixture).unwrap())
            .unwrap();
        assert_eq!(
            items[0].description.as_deref(),
            Some("Bold release under code next")
        );
        fixture[0]["body"] = serde_json::json!("## Heading\nhttps://example.com/only");
        assert_eq!(
            release()
                .parse(&serde_json::to_vec(&fixture).unwrap())
                .unwrap()[0]
                .description,
            None
        );
        fixture[0]["body"] = serde_json::json!("字".repeat(400));
        assert_eq!(
            release()
                .parse(&serde_json::to_vec(&fixture).unwrap())
                .unwrap()[0]
                .description
                .as_ref()
                .unwrap()
                .chars()
                .count(),
            300
        );
        fixture[0]["body"] =
            serde_json::json!("# Heading\n`https://example.com/only`\n**https://example.com/raw**");
        assert_eq!(
            release()
                .parse(&serde_json::to_vec(&fixture).unwrap())
                .unwrap()[0]
                .description,
            None
        );
    }

    #[test]
    fn release_descriptions_keep_issue_numbers_and_remove_only_headings() {
        let mut fixture: serde_json::Value =
            serde_json::from_slice(include_bytes!("fixtures/github/releases.json")).unwrap();
        for (body, expected) in [
            ("#123 fix leak", Some("#123 fix leak")),
            ("## What's Changed\n#123 fix leak", Some("#123 fix leak")),
            ("# Heading\n## Heading\n### Heading\n#### Heading\n##### Heading\n###### Heading\n#\n##\n######", None),
            ("##Not a heading\n####### Not a heading", Some("##Not a heading ####### Not a heading")),
        ] {
            fixture[0]["body"] = serde_json::json!(body);
            let items = release().parse(&serde_json::to_vec(&fixture).unwrap()).unwrap();
            assert_eq!(items[0].description.as_deref(), expected, "{body}");
        }
    }

    #[test]
    fn codex_and_opencode_keep_only_main_tag_prefixes() {
        let mut fixture: serde_json::Value =
            serde_json::from_slice(include_bytes!("fixtures/github/releases.json")).unwrap();
        let mut entries = Vec::new();
        for (id, tag) in [
            "rust-v1.0.0",
            "v1.0.0",
            "process-daemon-v0.5.0",
            "sdk-v1.0.0",
        ]
        .iter()
        .enumerate()
        {
            let mut entry = fixture[0].clone();
            entry["id"] = serde_json::json!(id);
            entry["tag_name"] = serde_json::json!(tag);
            entries.push(entry);
        }
        fixture = serde_json::json!(entries);
        let sources = releases();
        for (repo, expected_id) in [("openai/codex", "0"), ("anomalyco/opencode", "1")] {
            let source = sources
                .iter()
                .find(|s| s.info().id == format!("gh-release:{repo}"))
                .unwrap();
            let parsed = source
                .parse(&serde_json::to_vec(&fixture).unwrap())
                .unwrap();
            assert_eq!(parsed.len(), 1);
            assert_eq!(parsed[0].native_id, expected_id);
            assert!(source
                .parse(&serde_json::to_vec(&serde_json::json!([entries[2]])).unwrap())
                .unwrap()
                .is_empty());
        }
    }

    #[test]
    fn only_release_sources_declare_sixteen_mib() {
        for source in releases() {
            assert_eq!(source.max_body_bytes(), 16 * 1024 * 1024);
        }
        assert_eq!(new_repos().max_body_bytes(), 4 * 1024 * 1024);
    }
    use crate::sources::{Popularity, PopularityKind};

    fn release() -> Box<dyn Source> {
        releases().into_iter().next().unwrap()
    }

    #[test]
    fn release_registry_uses_verified_repositories() {
        let expected = [
            ("anthropics/claude-code", "Claude Code"),
            ("openai/codex", "Codex"),
            ("google-gemini/gemini-cli", "Gemini CLI"),
            ("anomalyco/opencode", "OpenCode"),
            ("earendil-works/pi", "Pi"),
            ("ollama/ollama", "Ollama"),
        ];
        let sources = releases();
        assert_eq!(sources.len(), expected.len());
        for (source, (repo, name)) in sources.iter().zip(expected) {
            let info = source.info();
            assert_eq!(info.id, format!("gh-release:{repo}"));
            assert_eq!(info.name, name);
            assert_eq!(info.category, Category::Tools);
            assert_eq!(info.home_url, format!("https://github.com/{repo}"));
            assert_eq!(
                source.url(0),
                format!("https://api.github.com/repos/{repo}/releases?per_page=20")
            );
            assert_eq!(source.accepts(), &["application/json"]);
        }
    }

    #[test]
    fn release_parser_maps_fields_and_skips_unpublished() {
        let items = release()
            .parse(include_bytes!("fixtures/github/releases.json"))
            .unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0],
            RawItem {
                origin: None,
                kind: None,
                native_id: "435979892".to_owned(),
                title: "0.167.0".to_owned(),
                url: "https://github.com/openai/codex/releases/tag/rust-v0.167.0".to_owned(),
                published_at: Some("2026-11-06T01:40:00Z".to_owned()),
                description: Some("Open the agent command center.".to_owned()),
                popularity: None,
            }
        );
        assert_eq!(items[1].title, "v2.0.0");
        assert_eq!(
            items[1].published_at.as_deref(),
            Some("2026-11-05T15:00:00Z")
        );
        assert_eq!(items[1].description, None);
    }

    #[test]
    fn release_parser_accepts_empty_list() {
        let items = release()
            .parse(include_bytes!("fixtures/github/releases-empty.json"))
            .unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn release_parser_allows_missing_date() {
        let items = release()
            .parse(include_bytes!("fixtures/github/releases-missing-date.json"))
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].published_at, None);
    }

    #[test]
    fn release_parser_rejects_changed_structure() {
        assert!(release()
            .parse(include_bytes!(
                "fixtures/github/releases-structure-changed.json"
            ))
            .is_err());
    }

    #[test]
    fn release_parser_rejects_when_all_candidates_invalid() {
        assert!(release()
            .parse(include_bytes!("fixtures/github/releases-invalid.json"))
            .is_err());
    }

    #[test]
    fn release_parser_returns_empty_for_only_prereleases() {
        let items = release()
            .parse(include_bytes!(
                "fixtures/github/releases-only-prereleases.json"
            ))
            .unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn new_repos_parser_maps_fields() {
        let items = new_repos()
            .parse(include_bytes!("fixtures/github/new-repos.json"))
            .unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0],
            RawItem {
                origin: None,
                kind: None,
                native_id: "101".to_owned(),
                title: "example/ai-helper".to_owned(),
                url: "https://github.com/example/ai-helper".to_owned(),
                published_at: Some("2026-11-05T15:00:00Z".to_owned()),
                description: Some("A local AI helper".to_owned()),
                popularity: Some(Popularity {
                    kind: PopularityKind::Stars,
                    value: 321,
                }),
            }
        );
    }

    #[test]
    fn new_repos_parser_accepts_empty_list() {
        let items = new_repos()
            .parse(include_bytes!("fixtures/github/new-repos-empty.json"))
            .unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn new_repos_parser_allows_missing_date() {
        let items = new_repos()
            .parse(include_bytes!(
                "fixtures/github/new-repos-missing-date.json"
            ))
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].published_at, None);
    }

    #[test]
    fn new_repos_parser_rejects_changed_structure() {
        assert!(new_repos()
            .parse(include_bytes!(
                "fixtures/github/new-repos-structure-changed.json"
            ))
            .is_err());
    }

    #[test]
    fn new_repos_parser_rejects_when_all_entries_invalid() {
        assert!(new_repos()
            .parse(include_bytes!("fixtures/github/new-repos-invalid.json"))
            .is_err());
    }

    #[test]
    fn new_repos_url_uses_utc_seven_day_window() {
        assert_eq!(
            new_repos().url(1_793_890_800_000),
            "https://api.github.com/search/repositories?q=created%3A%3E%3D2026-10-29%20topic%3Allm%2Cai-agent%2Cgenerative-ai%2Cmachine-learning&sort=stars&order=desc&per_page=30"
        );
    }
}
