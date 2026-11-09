use super::Result;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

#[derive(Clone, Default)]
pub struct Environment {
    pub platform: String,
    pub vars: HashMap<String, String>,
}
impl Environment {
    pub fn process() -> Self {
        Self {
            platform: if cfg!(windows) {
                "win32"
            } else if cfg!(target_os = "macos") {
                "darwin"
            } else {
                "linux"
            }
            .into(),
            vars: std::env::vars().collect(),
        }
    }
    fn get(&self, key: &str) -> Option<&str> {
        self.vars.get(key).map(String::as_str)
    }
    fn absolute(&self, key: &str, fallback: PathBuf) -> PathBuf {
        let s = self.get(key).unwrap_or("").replace(['\r', '\n'], "");
        if Path::new(&s).is_absolute() {
            PathBuf::from(s)
        } else {
            fallback
        }
    }
}

fn normalize(path: &Path) -> PathBuf {
    #[cfg(windows)]
    let native = PathBuf::from(path.to_string_lossy().replace('/', "\\"));
    #[cfg(not(windows))]
    let native = path.to_path_buf();
    let mut out = PathBuf::new();
    for part in native.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            _ => out.push(part.as_os_str()),
        }
    }
    out
}
fn entries(root: &Path) -> Vec<std::fs::DirEntry> {
    let mut list = std::fs::read_dir(root)
        .map(|r| r.filter_map(|e| e.ok()).collect::<Vec<_>>())
        .unwrap_or_default();
    list.sort_by_key(|e| e.file_name());
    list
}
fn wildcard(pattern: &str, name: &str) -> bool {
    let p = pattern.to_lowercase().into_bytes();
    let s = name.to_lowercase().into_bytes();
    let (mut i, mut j, mut star, mut mark) = (0, 0, None, 0);
    while j < s.len() {
        if i < p.len() && (p[i] == b'?' || p[i] == s[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == b'*' {
            star = Some(i);
            i += 1;
            mark = j;
        } else if let Some(k) = star {
            mark += 1;
            j = mark;
            i = k + 1;
        } else {
            return false;
        }
    }
    while p.get(i) == Some(&b'*') {
        i += 1;
    }
    i == p.len()
}
fn glob(root: &Path, pattern: &str) -> Vec<PathBuf> {
    if let Some(start) = pattern.find('{') {
        let end = start + pattern[start..].find('}').unwrap();
        let mut out = Vec::new();
        for choice in pattern[start + 1..end].split(',') {
            out.extend(glob(
                root,
                &format!("{}{choice}{}", &pattern[..start], &pattern[end + 1..]),
            ));
        }
        return out;
    }
    fn walk(root: &Path, parts: &[&str], out: &mut Vec<PathBuf>) {
        if parts.is_empty() {
            if root.is_file() {
                out.push(normalize(root));
            }
            return;
        }
        let part = parts[0];
        if part == "**" {
            walk(root, &parts[1..], out);
            for entry in entries(root) {
                if !entry.file_name().to_string_lossy().starts_with('.')
                    && entry.file_type().is_ok_and(|k| k.is_dir())
                {
                    walk(&entry.path(), parts, out);
                }
            }
        } else if part.contains(['*', '?']) {
            for entry in entries(root) {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with('.') && !part.starts_with('.') {
                    continue;
                }
                if wildcard(part, &name)
                    && (parts.len() == 1 || entry.file_type().is_ok_and(|k| k.is_dir()))
                {
                    walk(&entry.path(), &parts[1..], out);
                }
            }
        } else {
            walk(&root.join(part), &parts[1..], out);
        }
    }
    let mut out = Vec::new();
    walk(root, &pattern.split('/').collect::<Vec<_>>(), &mut out);
    out
}
fn global_bases(home: &Path, env: &Environment, ides: &[&str]) -> Vec<PathBuf> {
    let base = match env.platform.as_str() {
        "win32" => env.absolute("APPDATA", home.join("AppData/Roaming")),
        "darwin" => home.join("Library/Application Support"),
        _ => home.join(".config"),
    };
    ides.iter()
        .map(|ide| base.join(ide).join("User/globalStorage"))
        .collect()
}
fn openhands(root: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut pending = root.into_iter().collect::<Vec<_>>();
    while let Some(root) = pending.pop() {
        for entry in entries(&root) {
            if !entry.file_type().is_ok_and(|k| k.is_dir()) {
                continue;
            }
            let dir = entry.path();
            let state = dir.join("base_state.json");
            if state.is_file() {
                out.push(normalize(&state));
            }
            let sub = dir.join("subagents");
            if std::fs::symlink_metadata(&sub).is_ok_and(|m| m.is_dir()) {
                pending.push(sub);
            }
        }
    }
    out
}
fn codebuddy(home: &Path, env: &Environment) -> Vec<PathBuf> {
    fn walk(root: &Path, desktop: bool, out: &mut Vec<PathBuf>) {
        for entry in entries(root) {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let path = entry.path();
            if entry.file_type().is_ok_and(|k| k.is_dir()) {
                let ignored = if desktop {
                    &["messages", "check-point", "backups", "Public"][..]
                } else {
                    &["subagents"][..]
                };
                if !ignored.contains(&name.as_ref()) {
                    walk(&path, desktop, out);
                }
            } else if entry.file_type().is_ok_and(|k| k.is_file())
                && if desktop {
                    name == "index.json"
                        && root
                            .ancestors()
                            .nth(2)
                            .and_then(Path::file_name)
                            .is_some_and(|s| s == "history")
                } else {
                    name.ends_with(".jsonl")
                }
            {
                out.push(normalize(&path));
            }
        }
    }
    let mut out = Vec::new();
    for name in [".codebuddy", ".workbuddy", ".workbuddy-ai"] {
        walk(&home.join(name).join("projects"), false, &mut out);
    }
    let base = match env.platform.as_str() {
        "win32" => env.absolute("LOCALAPPDATA", home.join("AppData/Local")),
        "darwin" => home.join("Library/Application Support"),
        _ => home.join(".local/share"),
    };
    walk(&base.join("CodeBuddyExtension/Data"), true, &mut out);
    out
}
fn get_hermes_db_path(home: &Path, env: &Environment) -> PathBuf {
    normalize(&if env.platform == "win32" {
        env.absolute("LOCALAPPDATA", home.join("AppData/Local"))
            .join("hermes/state.db")
    } else {
        home.join(".hermes/state.db")
    })
}
fn get_cursor_state_db_path(home: &Path, env: &Environment) -> PathBuf {
    normalize(&global_bases(home, env, &["Cursor"])[0].join("state.vscdb"))
}
fn xdg_data(home: &Path, env: &Environment) -> PathBuf {
    env.absolute("XDG_DATA_HOME", home.join(".local/share"))
}
fn get_opencode_db_paths(home: &Path, env: &Environment) -> Vec<PathBuf> {
    let data = normalize(&xdg_data(home, env).join("opencode"));
    if let Some(value) = env.get("OPENCODE_DB") {
        if value == ":memory:" {
            return Vec::new();
        }
        // Unlike absoluteEnvPath, OPENCODE_DB preserves CR/LF and distinguishes an empty override.
        return vec![if Path::new(value).is_absolute() {
            PathBuf::from(value)
        } else {
            normalize(&data.join(value))
        }];
    }
    let mut files = vec![data.join("opencode.db")];
    files.extend(glob(home, ".opencode/opencode.db"));
    files
}
fn get_kilo_db_path(home: &Path, env: &Environment) -> Option<PathBuf> {
    let value = env.get("KILO_DB").unwrap_or("");
    if value == ":memory:" {
        return None;
    }
    Some(if Path::new(value).is_absolute() {
        PathBuf::from(value)
    } else {
        normalize(&xdg_data(home, env).join("kilo").join(if value.is_empty() {
            "kilo.db"
        } else {
            value
        }))
    })
}
fn get_mimocode_db_paths(home: &Path, env: &Environment) -> Vec<PathBuf> {
    let home_override = env.get("MIMOCODE_HOME").unwrap_or("");
    if !home_override.is_empty() && !Path::new(home_override).is_absolute() {
        return Vec::new();
    }
    let data = if home_override.is_empty() {
        xdg_data(home, env).join("mimocode")
    } else {
        Path::new(home_override).join("data")
    };
    let value = env.get("MIMOCODE_DB").unwrap_or("");
    if value == ":memory:" {
        return Vec::new();
    }
    if !value.is_empty() {
        return vec![if Path::new(value).is_absolute() {
            PathBuf::from(value)
        } else {
            normalize(&data.join(value))
        }];
    }
    let mut files = glob(&data, "mimocode.db");
    if matches!(
        env.get("MIMOCODE_DISABLE_CHANNEL_DB")
            .unwrap_or("")
            .to_lowercase()
            .as_str(),
        "false" | "0"
    ) {
        files.extend(glob(&data, "mimocode-*.db"));
    }
    files
}
fn get_goose_db_paths(home: &Path, env: &Environment) -> Vec<PathBuf> {
    let paths = match env.platform.as_str() {
        "win32" => vec![
            env.absolute("APPDATA", home.join("AppData/Roaming"))
                .join("goose/sessions/sessions.db"),
            env.absolute("LOCALAPPDATA", home.join("AppData/Local"))
                .join("block/goose/data.db"),
        ],
        "darwin" => vec![home.join("Library/Application Support/goose/sessions/sessions.db")],
        _ => vec![home.join(".local/share/goose/sessions/sessions.db")],
    };
    paths.iter().map(|p| normalize(p)).collect()
}
fn get_zed_db_path(home: &Path, env: &Environment) -> PathBuf {
    normalize(&match env.platform.as_str() {
        "win32" => env
            .absolute("LOCALAPPDATA", home.join("AppData/Local"))
            .join("Zed/threads/threads.db"),
        "darwin" => home.join("Library/Application Support/Zed/threads/threads.db"),
        _ => home.join(".local/share/zed/threads/threads.db"),
    })
}
fn get_anythingllm_db_path(home: &Path, env: &Environment) -> PathBuf {
    let base = match env.platform.as_str() {
        "win32" => env.absolute("APPDATA", home.join("AppData/Roaming")),
        "darwin" => home.join("Library/Application Support"),
        _ => home.join(".config"),
    };
    normalize(&base.join("anythingllm-desktop/storage/anythingllm.db"))
}
fn get_zcode_files(home: &Path, env: &Environment) -> Vec<PathBuf> {
    use serde_json::Value;
    fn read_json(path: &Path) -> Value {
        std::fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Value::Null)
    }
    let mut bases = vec![home.to_path_buf()];
    let settings = read_json(&home.join(".zcode/v2/setting.json"));
    for value in [
        env.get("ZCODE_DATA_BASE_DIR"),
        settings["dataBaseDir"].as_str(),
    ]
    .into_iter()
    .flatten()
    {
        let value = super::jscompat::trim(value);
        if Path::new(value).is_absolute()
            && !bases
                .iter()
                .any(|p| p.as_os_str() == std::ffi::OsStr::new(value))
        {
            bases.push(PathBuf::from(value));
        }
    }
    let mut files = Vec::new();
    for base in bases {
        files.push(normalize(&base.join(".zcode/cli/db/db.sqlite")));
        let config = read_json(&base.join(".zcode/cli/config.json"));
        for value in [
            config["storage"]["sessionDbPath"].as_str(),
            env.get("ZCODE_SESSION_DB_PATH"),
            env.get("ZCODE_SESSION_DB"),
        ]
        .into_iter()
        .flatten()
        {
            let value = super::jscompat::trim(value);
            if let Some(path) = value.strip_prefix("~/") {
                files.push(normalize(&base.join(path)));
            } else if Path::new(value).is_absolute() {
                files.push(PathBuf::from(value));
            }
        }
    }
    files
}

pub fn discover_with_env(home: &Path, env: &Environment) -> Result<Vec<(String, Vec<PathBuf>)>> {
    let home = normalize(home);
    let home = home.as_path();
    let mut out = Vec::new();
    let mut add = |source: &str, files: Vec<PathBuf>| {
        let mut unique = Vec::new();
        // Approved difference from Node's ineffective nodir option: only ordinary files enter discovery.
        for file in files.into_iter().filter(|file| file.is_file()) {
            if !unique
                .iter()
                .any(|p: &PathBuf| p.as_os_str() == file.as_os_str())
            {
                unique.push(file);
            }
        }
        out.push((source.into(), unique));
    };
    for (source, root, pattern) in [
        ("claude", ".claude/projects", "**/*.jsonl"),
        ("codex", ".codex/sessions", "**/rollout-*.{jsonl,jsonl.zst}"),
        ("qwen", ".qwen/usage", "*-usage-*.jsonl"),
        ("dsh", ".dsh/storages/session_projcache/sessions", "*.json"),
        ("grok", ".grok/sessions", "*/*/updates.jsonl"),
        ("aider", "", ".aider.llm.history"),
        ("pi", ".pi/agent/sessions", "**/*.jsonl"),
    ] {
        add(source, glob(&home.join(root), pattern));
    }
    add("hermes", vec![get_hermes_db_path(home, env)]);
    let mut files = Vec::new();
    for base in global_bases(
        home,
        env,
        &["Code", "Code - Insiders", "VSCodium", "Cursor"],
    ) {
        for ext in ["saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline"] {
            files.extend(glob(
                &base.join(ext).join("tasks"),
                "*/api_conversation_history.json",
            ));
        }
    }
    add("cline", files);
    let mut files = glob(
        &env.absolute("GEMINI_HOME", home.join(".gemini")),
        "sessions/**/*.{json,jsonl}",
    );
    files.extend(glob(
        &home.join(".config/gemini"),
        "sessions/**/*.{json,jsonl}",
    ));
    add("gemini", files);
    let mut files = vec![get_cursor_state_db_path(home, env)];
    files.extend(glob(home, "*cursor*.csv"));
    add("cursor", files);
    add("opencode", get_opencode_db_paths(home, env));
    add("kilo", get_kilo_db_path(home, env).into_iter().collect());
    let root = if let Some(s) = env.get("OPENHANDS_CONVERSATIONS_DIR") {
        Path::new(s).is_absolute().then(|| PathBuf::from(s))
    } else if let Some(s) = env.get("OPENHANDS_PERSISTENCE_DIR") {
        Path::new(s)
            .is_absolute()
            .then(|| Path::new(s).join("conversations"))
    } else {
        Some(home.join(".openhands/conversations"))
    };
    add("openhands", openhands(root));
    let mut files = get_goose_db_paths(home, env);
    files.extend(glob(
        &env.absolute("GOOSE_PATH_ROOT", home.join(".goose")),
        "data/sessions/sessions.db",
    ));
    add("goose", files);
    let mut files = vec![get_zed_db_path(home, env)];
    files.extend(glob(home, ".local/share/zed/threads/threads.db"));
    add("zed", files);
    add("continue", glob(&home.join(".continue/sessions"), "*.json"));
    let mut files = glob(home, "*trae*.{json,jsonl}");
    for base in global_bases(home, env, &["TRAE SOLO", "Trae CN", "TRAE SOLO CN", "trae"]) {
        files.extend(glob(&base, "**/*trae*.{json,jsonl}"));
    }
    add("trae", files);
    add(
        "copilot",
        glob(
            &env.absolute("COPILOT_HOME", home.join(".copilot")),
            "{session-store.db,data.db}",
        ),
    );
    add(
        "openclaw",
        glob(
            &env.absolute(
                "OPENCLAW_HOME",
                env.absolute("OPENCLAW_STATE_DIR", home.join(".openclaw")),
            ),
            "agents/*/{sessions,session-sqlite-import-archive}/*.jsonl*",
        ),
    );
    let mut files = get_mimocode_db_paths(home, env);
    files.extend(glob(
        &env.absolute("APPDATA", home.join("AppData/Roaming")),
        "Xiaomi MiMo/mimocode/mimocode.db",
    ));
    add("mimo", files);
    let mut files = glob(&home.join(".kimi-code"), "sessions/*/*/agents/*/wire.jsonl");
    let share = env
        .get("KIMI_SHARE_DIR")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".kimi"));
    if share.is_absolute() {
        files.extend(glob(&share, "{sessions,logs}/**/*.{json,jsonl}"));
    }
    for base in [
        env.absolute("APPDATA", home.join("AppData/Roaming")),
        env.absolute("LOCALAPPDATA", home.join("AppData/Local")),
    ] {
        files.extend(glob(&base, "{kimi,Kimi}/{sessions,logs}/**/*.{json,jsonl}"));
    }
    files.extend(glob(
        &home.join(".config/kimi"),
        "{sessions,logs}/**/*.{json,jsonl}",
    ));
    add("kimi", files);
    let value = env.get("MINIMAX_DATA_DIR").unwrap_or("");
    let files = if value.is_empty() {
        let mut files = glob(&home.join(".minimax"), "v2/sqlite/runtime-state.sqlite");
        // Node glob processes matched directories using a LIFO work list.
        files.extend(
            glob(home, ".minimax-*/v2/sqlite/runtime-state.sqlite")
                .into_iter()
                .rev(),
        );
        files
    } else if Path::new(value).is_absolute() {
        glob(Path::new(value), "v2/sqlite/runtime-state.sqlite")
    } else {
        Vec::new()
    };
    add("minimax", files);
    add("codebuddy", codebuddy(home, env));
    add("zcode", get_zcode_files(home, env));
    add(
        "commandcode",
        glob(&home.join(".commandcode/projects"), "*/*.jsonl")
            .into_iter()
            .filter(|p| {
                let s = p.to_string_lossy();
                !s.ends_with(".checkpoints.jsonl") && !s.ends_with(".prompts.jsonl")
            })
            .collect(),
    );
    add("anythingllm", vec![get_anythingllm_db_path(home, env)]);
    Ok(out)
}
#[cfg(test)]
pub fn discover(home: &Path) -> Result<Vec<(String, Vec<PathBuf>)>> {
    discover_with_env(
        home,
        &Environment {
            platform: if cfg!(windows) { "win32" } else { "darwin" }.into(),
            vars: HashMap::new(),
        },
    )
}
#[cfg(all(test, windows))]
mod tests {
    use super::*;
    #[test]
    fn overridden_home_uses_native_discovery_paths() {
        let directory = tempfile::tempdir().unwrap();
        let logs = directory.path().join(".claude").join("projects");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("a.jsonl"), "").unwrap();
        let override_home = directory.path().to_string_lossy().replace('\\', "/");
        let found = discover(Path::new(&override_home)).unwrap();
        assert_eq!(
            found[0].1[0].to_string_lossy(),
            logs.join("a.jsonl").to_string_lossy()
        );
    }
}

#[cfg(test)]
mod b2_tests {
    use super::*;
    use serde_json::Value;
    #[test]
    fn discovery_matches_node_b2() {
        for line in include_str!("../../tests/golden/discovery-b2.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            let dir = tempfile::tempdir().unwrap();
            let home = dir.path();
            for file in row["files"].as_array().unwrap() {
                let path = home.join(file.as_str().unwrap());
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(path, b"{}").unwrap();
            }
            for dir in row["directories"].as_array().unwrap() {
                std::fs::create_dir_all(home.join(dir.as_str().unwrap())).unwrap();
            }
            let vars = row["env"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| {
                    (
                        k.clone(),
                        if let Some(s) = v.as_str() {
                            home.join(s).to_string_lossy().into_owned()
                        } else {
                            v["literal"].as_str().unwrap().into()
                        },
                    )
                })
                .collect();
            let env = Environment {
                platform: "win32".into(),
                vars,
            };
            let found = discover_with_env(home, &env).unwrap();
            for (source, expected) in row["expected"].as_object().unwrap() {
                let mut actual: Vec<String> = found
                    .iter()
                    .find(|(s, _)| s == source)
                    .map(|(_, files)| {
                        files
                            .iter()
                            .map(|p| {
                                p.strip_prefix(home)
                                    .unwrap()
                                    .to_string_lossy()
                                    .replace('\\', "/")
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                actual.sort();
                assert_eq!(
                    serde_json::json!(actual),
                    *expected,
                    "{} {source}",
                    row["scenario"]
                );
            }
        }
    }
}

#[cfg(test)]
mod platform_tests {
    use super::*;
    #[test]
    fn macos_roots_and_override_rules() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let paths=["Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/a/api_conversation_history.json","Library/Application Support/Trae CN/User/globalStorage/a/trae.json","Library/Application Support/CodeBuddyExtension/Data/history/w/c/index.json",".gemini/sessions/a.json",".openhands/conversations/a/base_state.json",".kimi/sessions/a.json",".openclaw/agents/a/sessions/a.jsonl"];
        for file in paths {
            let file = home.join(file);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, "{}").unwrap();
        }
        let mut env = Environment {
            platform: "darwin".into(),
            vars: HashMap::new(),
        };
        let found = discover_with_env(home, &env).unwrap();
        for source in [
            "cline",
            "trae",
            "codebuddy",
            "gemini",
            "openhands",
            "kimi",
            "openclaw",
        ] {
            assert_eq!(
                found.iter().find(|(s, _)| s == source).unwrap().1.len(),
                1,
                "{source}"
            );
        }
        for key in ["GEMINI_HOME", "OPENCLAW_HOME", "APPDATA", "LOCALAPPDATA"] {
            env.vars.insert(key.into(), "relative\r\n".into());
        }
        assert_eq!(
            env.absolute("GEMINI_HOME", home.join(".gemini")),
            home.join(".gemini")
        );
        let absolute = home.join(".gemini").to_string_lossy().into_owned();
        env.vars
            .insert("GEMINI_HOME".into(), format!("{absolute}\r\n"));
        assert_eq!(
            env.absolute("GEMINI_HOME", PathBuf::new()),
            home.join(".gemini")
        );
        env.vars
            .insert("OPENHANDS_CONVERSATIONS_DIR".into(), String::new());
        env.vars.insert("KIMI_SHARE_DIR".into(), "relative".into());
        let found = discover_with_env(home, &env).unwrap();
        for source in ["openhands", "kimi"] {
            assert!(found
                .iter()
                .find(|(s, _)| s == source)
                .unwrap()
                .1
                .is_empty());
        }
        env.vars.remove("OPENHANDS_CONVERSATIONS_DIR");
        env.vars.insert(
            "OPENHANDS_PERSISTENCE_DIR".into(),
            home.join(".openhands").to_string_lossy().into_owned(),
        );
        assert_eq!(
            discover_with_env(home, &env)
                .unwrap()
                .iter()
                .find(|(s, _)| s == "openhands")
                .unwrap()
                .1
                .len(),
            1
        );
    }
}

#[cfg(test)]
mod b3_tests {
    use super::*;
    use serde_json::{json, Value};
    fn expand(value: &Value, home: &Path) -> Value {
        if let Some(path) = value.get("home").and_then(Value::as_str) {
            let path = format!(
                "{}{}",
                normalize(&home.join(path)).display(),
                value["suffix"].as_str().unwrap_or("")
            );
            json!(if value["slashes"] == "forward" {
                path.replace('\\', "/")
            } else {
                path
            })
        } else if let Some(literal) = value.get("literal") {
            literal.clone()
        } else if let Some(obj) = value.as_object() {
            Value::Object(
                obj.iter()
                    .map(|(k, v)| (k.clone(), expand(v, home)))
                    .collect(),
            )
        } else {
            value.clone()
        }
    }
    #[test]
    fn discovery_matches_node_b3() {
        for line in include_str!("../../tests/golden/discovery-b3.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            let dir = tempfile::tempdir().unwrap();
            let home = dir.path();
            for file in row["files"].as_array().unwrap() {
                let path = home.join(file.as_str().unwrap());
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(path, "{}").unwrap();
            }
            for path in row["directories"].as_array().unwrap() {
                std::fs::create_dir_all(home.join(path.as_str().unwrap())).unwrap();
            }
            for entry in row["json"].as_array().unwrap() {
                let path = home.join(entry["file"].as_str().unwrap());
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                let text = entry["value"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| expand(&entry["value"], home).to_string());
                std::fs::write(path, text).unwrap();
            }
            let env = Environment {
                platform: row["platform"].as_str().unwrap().into(),
                vars: row["env"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| {
                        (
                            k.clone(),
                            if let Some(s) = v.as_str() {
                                normalize(&home.join(s)).to_string_lossy().into_owned()
                            } else {
                                expand(v, home).as_str().unwrap().into()
                            },
                        )
                    })
                    .collect(),
            };
            let found = discover_with_env(home, &env).unwrap();
            for (source, expected) in row["expected"].as_object().unwrap() {
                let actual = found
                    .iter()
                    .find(|(s, _)| s == source)
                    .map(|(_, files)| {
                        files
                            .iter()
                            .map(|p| {
                                p.strip_prefix(home)
                                    .unwrap()
                                    .to_string_lossy()
                                    .replace('\\', "/")
                            })
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                assert_eq!(json!(actual), *expected, "{} {source}", row["scenario"]);
                let suffixes = found
                    .iter()
                    .find(|(s, _)| s == source)
                    .map(|(_, files)| {
                        files
                            .iter()
                            .map(|p| p.to_string_lossy()[home.to_string_lossy().len()..].to_owned())
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                assert_eq!(
                    json!(suffixes),
                    row["identity_suffixes"][source],
                    "identity {} {source}",
                    row["scenario"]
                );
            }
        }
    }
    #[test]
    fn macos_sqlite_roots_b3() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let paths = [
            ("hermes", ".hermes/state.db"),
            (
                "cursor",
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            ),
            ("opencode", ".local/share/opencode/opencode.db"),
            ("kilo", ".local/share/kilo/kilo.db"),
            (
                "goose",
                "Library/Application Support/goose/sessions/sessions.db",
            ),
            ("zed", "Library/Application Support/Zed/threads/threads.db"),
            ("copilot", ".copilot/session-store.db"),
            ("mimo", ".local/share/mimocode/mimocode.db"),
            ("minimax", ".minimax/v2/sqlite/runtime-state.sqlite"),
            ("zcode", ".zcode/cli/db/db.sqlite"),
            (
                "anythingllm",
                "Library/Application Support/anythingllm-desktop/storage/anythingllm.db",
            ),
        ];
        for (_, file) in paths {
            let file = home.join(file);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, "{}").unwrap();
        }
        let env = Environment {
            platform: "darwin".into(),
            vars: HashMap::new(),
        };
        let found = discover_with_env(home, &env).unwrap();
        assert_eq!(found.len(), 27);
        for (source, file) in paths {
            assert_eq!(
                found.iter().find(|(s, _)| s == source).unwrap().1,
                vec![normalize(&home.join(file))],
                "{source}"
            );
        }
    }
    #[test]
    fn absolute_overrides_preserve_identity_b3() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let path = home.join("override.db");
        std::fs::write(&path, "{}").unwrap();
        let identity = path.to_string_lossy().replace('\\', "/");
        let mut env = Environment {
            platform: "win32".into(),
            vars: HashMap::new(),
        };
        for (source, key) in [
            ("opencode", "OPENCODE_DB"),
            ("kilo", "KILO_DB"),
            ("mimo", "MIMOCODE_DB"),
            ("zcode", "ZCODE_SESSION_DB"),
        ] {
            env.vars.insert(key.into(), identity.clone());
            let found = discover_with_env(home, &env).unwrap();
            let files = &found.iter().find(|(s, _)| s == source).unwrap().1;
            assert_eq!(files.len(), 1);
            assert_eq!(files[0].to_string_lossy(), identity, "{source}");
        }
    }
}
