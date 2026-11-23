use super::Result;
use crate::api::stats::{StatsDiscoveredTool, StatsLogDirectory};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsString;
use std::fs::{self, DirEntry, FileType};
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;
use std::time::Instant;

#[derive(Clone, Default)]
pub struct Environment {
    pub platform: String,
    pub vars: HashMap<String, String>,
    pub preview: bool,
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
            preview: false,
        }
    }
    pub fn preview(&self) -> Self {
        Self {
            platform: self.platform.clone(),
            preview: true,
            ..Self::default()
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
#[derive(Default, Serialize)]
pub(crate) struct DiscoveryIssue {
    pub source: String,
    pub permission_denied: usize,
    pub io_errors: usize,
    pub unreadable_entries: usize,
}

impl DiscoveryIssue {
    pub fn counts(&self) -> [(&'static str, usize); 3] {
        [
            ("permission_denied", self.permission_denied),
            ("io_errors", self.io_errors),
            ("unreadable_entries", self.unreadable_entries),
        ]
    }

    pub fn from_run(source: &str, counts: &serde_json::Value) -> Option<Self> {
        let count = |kind| {
            counts[format!("discovery.{source}.{kind}")]
                .as_u64()
                .unwrap_or(0) as usize
        };
        let issue = Self {
            source: source.into(),
            permission_denied: count("permission_denied"),
            io_errors: count("io_errors"),
            unreadable_entries: count("unreadable_entries"),
        };
        issue.counts().iter().any(|(_, n)| *n != 0).then_some(issue)
    }
}

struct Scan<'a> {
    preview: Option<&'a Path>,
    issue: DiscoveryIssue,
    failed_dirs: HashSet<PathBuf>,
    checked_dirs: HashSet<PathBuf>,
    failed_entries: HashSet<PathBuf>,
    path_errors: Option<Vec<(PathBuf, ErrorKind)>>,
    verified_glob_files: HashSet<OsString>,
    #[cfg(test)]
    io_counts: ScanIoCounts,
    #[cfg(test)]
    iteration_errors: HashMap<PathBuf, ErrorKind>,
}

#[cfg(test)]
#[derive(Default)]
struct ScanIoCounts {
    read_dir: usize,
    metadata: usize,
    reads_by_dir: Option<HashMap<PathBuf, usize>>,
}

impl<'a> Scan<'a> {
    fn new(home: &'a Path, env: &Environment) -> Self {
        Self {
            preview: env.preview.then_some(home),
            issue: DiscoveryIssue::default(),
            failed_dirs: HashSet::new(),
            checked_dirs: HashSet::new(),
            failed_entries: HashSet::new(),
            path_errors: None,
            verified_glob_files: HashSet::new(),
            #[cfg(test)]
            io_counts: ScanIoCounts::default(),
            #[cfg(test)]
            iteration_errors: HashMap::new(),
        }
    }

    fn allowed(&self, path: &Path) -> io::Result<bool> {
        let Some(home) = self.preview else {
            return Ok(true);
        };
        let Ok(relative) = path.strip_prefix(home) else {
            return Ok(false);
        };
        let mut current = home.to_path_buf();
        if linked(&fs::symlink_metadata(&current)?) {
            return Ok(false);
        }
        let mut parts = relative.components().peekable();
        while let Some(part) = parts.next() {
            let Component::Normal(name) = part else {
                return Ok(false);
            };
            current.push(name);
            let metadata = fs::symlink_metadata(&current)?;
            if linked(&metadata) {
                return Ok(false);
            }
            if parts.peek().is_some() && !metadata.is_dir() {
                return Err(ErrorKind::NotADirectory.into());
            }
        }
        Ok(true)
    }

    fn dir_error(&mut self, path: &Path, error: io::Error) {
        if error.kind() == ErrorKind::NotFound || !self.failed_dirs.insert(normalize(path)) {
            return;
        }
        self.record_error(path, error.kind());
        match error.kind() {
            ErrorKind::PermissionDenied => self.issue.permission_denied += 1,
            _ => self.issue.io_errors += 1,
        }
    }

    fn read_dir<T>(&mut self, root: &Path, read: impl FnOnce(&Path) -> io::Result<T>) -> Option<T> {
        let allowed = self.allowed(root);
        #[cfg(test)]
        let read = |path: &Path| {
            self.io_counts.read_dir += 1;
            if let Some(dirs) = &mut self.io_counts.reads_by_dir {
                *dirs.entry(normalize(path)).or_default() += 1;
            }
            read(path)
        };
        match allowed.and_then(|allowed| allowed.then(|| read(root)).transpose()) {
            Ok(entries) => entries,
            Err(error) => {
                self.dir_error(root, error);
                None
            }
        }
    }

    fn entries(&mut self, root: &Path) -> Vec<DirEntry> {
        self.checked_dirs.insert(normalize(root));
        let (mut list, errors) = self.list_entries(root);
        self.report_iteration_errors(root, &errors);
        list.sort_by_key(|entry| entry.file_name());
        list
    }

    fn list_entries(&mut self, root: &Path) -> (Vec<DirEntry>, Vec<ErrorKind>) {
        let entries = self.read_dir(root, |path| fs::read_dir(path));
        #[cfg(test)]
        let injected = self
            .iteration_errors
            .get(root)
            .copied()
            .map(io::Error::from);
        let entries = entries.into_iter().flatten();
        #[cfg(test)]
        let entries = entries.chain(injected.map(Err));
        Self::read_entries(entries)
    }

    fn report_iteration_errors(&mut self, root: &Path, errors: &[ErrorKind]) {
        self.issue.unreadable_entries += errors.len();
        for &kind in errors {
            self.record_error(root, kind);
        }
    }

    fn read_entries<T>(entries: impl Iterator<Item = io::Result<T>>) -> (Vec<T>, Vec<ErrorKind>) {
        let mut list = Vec::new();
        let mut errors = Vec::new();
        for entry in entries {
            match entry {
                Ok(entry) => list.push(entry),
                Err(error) => errors.push(error.kind()),
            }
        }
        (list, errors)
    }

    fn entry_type(&mut self, entry: &DirEntry) -> Option<FileType> {
        match entry.file_type() {
            Ok(kind) => Some(kind),
            Err(error) => {
                self.report_type_error(&entry.path(), error.kind());
                None
            }
        }
    }

    fn report_type_error(&mut self, path: &Path, kind: ErrorKind) {
        self.record_error(path, kind);
        self.entry_error(path);
    }

    fn record_error(&mut self, path: &Path, kind: ErrorKind) {
        if let Some(errors) = &mut self.path_errors {
            errors.push((normalize(path), kind));
        }
    }

    fn entry_error(&mut self, path: &Path) {
        if self.failed_entries.insert(normalize(path)) {
            self.issue.unreadable_entries += 1;
        }
    }

    fn file(&mut self, path: &Path) -> bool {
        // A fixed filename can be stat'ed on systems that deny listing its parent.
        if let Some(parent) = path.parent() {
            if self.checked_dirs.insert(normalize(parent)) {
                self.read_dir(parent, |path| fs::read_dir(path));
            }
        }
        self.stat_file(path)
    }

    fn stat_file(&mut self, path: &Path) -> bool {
        let allowed = self.allowed(path);
        match allowed.and_then(|allowed| {
            allowed
                .then(|| {
                    #[cfg(test)]
                    {
                        self.io_counts.metadata += 1;
                    }
                    fs::metadata(path)
                })
                .transpose()
        }) {
            Ok(metadata) => metadata.is_some_and(|metadata| metadata.is_file()),
            Err(error) => {
                if error.kind() != ErrorKind::NotFound
                    && !path
                        .parent()
                        .is_some_and(|parent| self.failed_dirs.contains(&normalize(parent)))
                {
                    self.record_error(path, error.kind());
                    self.entry_error(path);
                }
                false
            }
        }
    }

    fn take_issue(&mut self, source: &str) -> DiscoveryIssue {
        self.failed_dirs.clear();
        self.checked_dirs.clear();
        self.failed_entries.clear();
        self.verified_glob_files.clear();
        let mut issue = std::mem::take(&mut self.issue);
        issue.source = source.into();
        issue
    }
}

fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

pub(super) fn preview_allows_sqlite(home: &Path, path: &Path) -> bool {
    let home = normalize(home);
    let environment = Environment::default().preview();
    let scan = Scan::new(&home, &environment);
    scan.allowed(path).unwrap_or(false)
        && ["-wal", "-shm", "-journal"].iter().all(|suffix| {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            match scan.allowed(Path::new(&name)) {
                Ok(allowed) => allowed,
                Err(error) => error.kind() == ErrorKind::NotFound,
            }
        })
}

const ANTIGRAVITY_CONVERSATIONS: &str = ".gemini/antigravity-cli/conversations";

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
fn glob(scan: &mut Scan<'_>, root: &Path, pattern: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    // Only recursive walks and wildcard alternatives can list a directory again.
    let share_listings =
        pattern.contains("**") || (pattern.contains('{') && pattern.contains(['*', '?']));
    let mut glob = Glob {
        directories: share_listings.then(HashMap::new),
    };
    glob.expand(scan, root, pattern, &mut out);
    out
}

struct Glob {
    directories: Option<HashMap<PathBuf, Rc<GlobDirectory>>>,
}

struct GlobDirectory {
    entries: Vec<GlobEntry>,
    errors: Vec<ErrorKind>,
}

struct GlobEntry {
    name: OsString,
    kind: std::result::Result<FileType, ErrorKind>,
}

impl GlobEntry {
    fn is_dir(&self, scan: &mut Scan<'_>, parent: &Path) -> bool {
        match self.kind {
            Ok(kind) => kind.is_dir(),
            Err(error) => {
                scan.report_type_error(&parent.join(&self.name), error);
                false
            }
        }
    }
}

impl Glob {
    fn directory(&mut self, scan: &mut Scan<'_>, root: &Path) -> Rc<GlobDirectory> {
        if let Some(directory) = self.directories.as_ref().and_then(|dirs| dirs.get(root)) {
            return Rc::clone(directory);
        }
        scan.checked_dirs.insert(normalize(root));
        let (entries, errors) = scan.list_entries(root);
        // Keep names and types only. DirEntry can keep a directory handle open on Unix.
        let mut entries: Vec<_> = entries
            .into_iter()
            .map(|entry| GlobEntry {
                name: entry.file_name(),
                kind: entry.file_type().map_err(|error| error.kind()),
            })
            .collect();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        let directory = Rc::new(GlobDirectory { entries, errors });
        if let Some(dirs) = &mut self.directories {
            dirs.insert(root.to_owned(), Rc::clone(&directory));
        }
        directory
    }

    fn entries(&mut self, scan: &mut Scan<'_>, root: &Path) -> Rc<GlobDirectory> {
        let directory = self.directory(scan, root);
        // A partial listing counted once per logical pass, in traversal order.
        scan.report_iteration_errors(root, &directory.errors);
        directory
    }

    fn expand(&mut self, scan: &mut Scan<'_>, root: &Path, pattern: &str, out: &mut Vec<PathBuf>) {
        if let Some(start) = pattern.find('{') {
            let end = start + pattern[start..].find('}').unwrap();
            for choice in pattern[start + 1..end].split(',') {
                self.expand(
                    scan,
                    root,
                    &format!("{}{choice}{}", &pattern[..start], &pattern[end + 1..]),
                    out,
                );
            }
        } else {
            self.walk(scan, root, &pattern.split('/').collect::<Vec<_>>(), out);
        }
    }

    fn walk(&mut self, scan: &mut Scan<'_>, root: &Path, parts: &[&str], out: &mut Vec<PathBuf>) {
        let Some((&part, rest)) = parts.split_first() else {
            // A fixed filename can be stat'ed even if the parent cannot be listed.
            let is_file = if self.directories.is_some() {
                if let Some(parent) = root.parent() {
                    if !scan.checked_dirs.contains(&normalize(parent)) {
                        self.directory(scan, parent);
                    }
                }
                scan.stat_file(root)
            } else {
                scan.file(root)
            };
            if is_file {
                out.push(normalize(root));
            }
            return;
        };
        if part == "**" {
            self.walk(scan, root, rest, out);
            for entry in &self.entries(scan, root).entries {
                if !entry.name.to_string_lossy().starts_with('.') && entry.is_dir(scan, root) {
                    self.walk(scan, &root.join(&entry.name), parts, out);
                }
            }
        } else if part.contains(['*', '?']) {
            for entry in &self.entries(scan, root).entries {
                let name = entry.name.to_string_lossy();
                if (name.starts_with('.') && !part.starts_with('.')) || !wildcard(part, &name) {
                    continue;
                }
                if rest.is_empty() {
                    let path = root.join(&entry.name);
                    if scan.stat_file(&path) {
                        let normalized = normalize(&path);
                        // Listing a directory can succeed even when stat on a child fails.
                        // Reuse a successful stat only for ordinary, non-preview entries.
                        if scan.preview.is_none()
                            && entry.kind.is_ok_and(|kind| kind.is_file())
                            && path == normalized
                        {
                            scan.verified_glob_files
                                .insert(normalized.as_os_str().to_owned());
                        }
                        out.push(normalized);
                    }
                } else if entry.is_dir(scan, root) {
                    self.walk(scan, &root.join(&entry.name), rest, out);
                }
            }
        } else {
            self.walk(scan, &root.join(part), rest, out);
        }
    }
}

#[cfg(test)]
fn legacy_glob(scan: &mut Scan<'_>, root: &Path, pattern: &str) -> Vec<PathBuf> {
    if let Some(start) = pattern.find('{') {
        let end = start + pattern[start..].find('}').unwrap();
        let mut out = Vec::new();
        for choice in pattern[start + 1..end].split(',') {
            out.extend(legacy_glob(
                scan,
                root,
                &format!("{}{choice}{}", &pattern[..start], &pattern[end + 1..]),
            ));
        }
        return out;
    }
    fn walk(scan: &mut Scan<'_>, root: &Path, parts: &[&str], out: &mut Vec<PathBuf>) {
        if parts.is_empty() {
            if scan.file(root) {
                out.push(normalize(root));
            }
            return;
        }
        let part = parts[0];
        if part == "**" {
            walk(scan, root, &parts[1..], out);
            for entry in scan.entries(root) {
                if !entry.file_name().to_string_lossy().starts_with('.')
                    && scan.entry_type(&entry).is_some_and(|k| k.is_dir())
                {
                    walk(scan, &entry.path(), parts, out);
                }
            }
        } else if part.contains(['*', '?']) {
            for entry in scan.entries(root) {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with('.') && !part.starts_with('.') {
                    continue;
                }
                if wildcard(part, &name)
                    && (parts.len() == 1 || scan.entry_type(&entry).is_some_and(|k| k.is_dir()))
                {
                    walk(scan, &entry.path(), &parts[1..], out);
                }
            }
        } else {
            walk(scan, &root.join(part), &parts[1..], out);
        }
    }
    let mut out = Vec::new();
    walk(
        scan,
        root,
        &pattern.split('/').collect::<Vec<_>>(),
        &mut out,
    );
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
fn openhands(scan: &mut Scan<'_>, root: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut pending = root.into_iter().collect::<Vec<_>>();
    while let Some(root) = pending.pop() {
        for entry in scan.entries(&root) {
            if !scan.entry_type(&entry).is_some_and(|k| k.is_dir()) {
                continue;
            }
            let dir = entry.path();
            let state = dir.join("base_state.json");
            if scan.file(&state) {
                out.push(normalize(&state));
            }
            let sub = dir.join("subagents");
            let metadata = scan
                .allowed(&sub)
                .and_then(|allowed| allowed.then(|| fs::symlink_metadata(&sub)).transpose());
            match metadata {
                Ok(Some(metadata)) if metadata.is_dir() => pending.push(sub),
                Err(error) => scan.dir_error(&sub, error),
                _ => {}
            }
        }
    }
    out
}
fn codebuddy(scan: &mut Scan<'_>, home: &Path, env: &Environment) -> Vec<PathBuf> {
    fn walk(scan: &mut Scan<'_>, root: &Path, desktop: bool, out: &mut Vec<PathBuf>) {
        for entry in scan.entries(root) {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let path = entry.path();
            let kind = scan.entry_type(&entry);
            if kind.is_some_and(|k| k.is_dir()) {
                let ignored = if desktop {
                    &["messages", "check-point", "backups", "Public"][..]
                } else {
                    &["subagents"][..]
                };
                if !ignored.contains(&name.as_ref()) {
                    walk(scan, &path, desktop, out);
                }
            } else if kind.is_some_and(|k| k.is_file())
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
        walk(scan, &home.join(name).join("projects"), false, &mut out);
    }
    let base = match env.platform.as_str() {
        "win32" => env.absolute("LOCALAPPDATA", home.join("AppData/Local")),
        "darwin" => home.join("Library/Application Support"),
        _ => home.join(".local/share"),
    };
    walk(scan, &base.join("CodeBuddyExtension/Data"), true, &mut out);
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
fn get_opencode_db_paths(scan: &mut Scan<'_>, home: &Path, env: &Environment) -> Vec<PathBuf> {
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
    files.extend(glob(scan, home, ".opencode/opencode.db"));
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
fn get_mimocode_db_paths(scan: &mut Scan<'_>, home: &Path, env: &Environment) -> Vec<PathBuf> {
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
    let mut files = glob(scan, &data, "mimocode.db");
    if matches!(
        env.get("MIMOCODE_DISABLE_CHANNEL_DB")
            .unwrap_or("")
            .to_lowercase()
            .as_str(),
        "false" | "0"
    ) {
        files.extend(glob(scan, &data, "mimocode-*.db"));
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
fn get_zcode_files(scan: &mut Scan<'_>, home: &Path, env: &Environment) -> Vec<PathBuf> {
    use serde_json::Value;
    fn read_json(scan: &mut Scan<'_>, path: &Path) -> Value {
        if !scan.file(path) {
            return Value::Null;
        }
        match fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or(Value::Null),
            Err(error) => {
                if error.kind() != ErrorKind::NotFound {
                    scan.record_error(path, error.kind());
                    scan.entry_error(path);
                }
                Value::Null
            }
        }
    }
    let mut bases = vec![home.to_path_buf()];
    let settings = read_json(scan, &home.join(".zcode/v2/setting.json"));
    for value in [
        env.get("ZCODE_DATA_BASE_DIR"),
        settings["dataBaseDir"].as_str(),
    ]
    .into_iter()
    .flatten()
    {
        let value = super::jscompat::trim(value);
        let path = Path::new(value);
        if Path::new(value).is_absolute()
            && (!env.preview || normalize(path).starts_with(home))
            && !bases
                .iter()
                .any(|p| p.as_os_str() == std::ffi::OsStr::new(value))
        {
            bases.push(if env.preview {
                normalize(path)
            } else {
                path.into()
            });
        }
    }
    let mut files = Vec::new();
    for base in bases {
        files.push(normalize(&base.join(".zcode/cli/db/db.sqlite")));
        let config = read_json(scan, &base.join(".zcode/cli/config.json"));
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
    if env.preview {
        files = files
            .into_iter()
            .map(|path| normalize(&path))
            .filter(|path| path.starts_with(home))
            .collect();
    }
    files
}

fn windows_app_data(home: &Path, env: &Environment) -> [PathBuf; 2] {
    [
        env.absolute("APPDATA", home.join("AppData/Roaming")),
        env.absolute("LOCALAPPDATA", home.join("AppData/Local")),
    ]
}

fn mimo_desktop_root(home: &Path, env: &Environment) -> Option<PathBuf> {
    (env.platform == "win32").then(|| {
        env.absolute("APPDATA", home.join("AppData/Roaming"))
            .join("Xiaomi MiMo/mimocode")
    })
}

fn kimi_desktop_roots(home: &Path, env: &Environment) -> impl Iterator<Item = PathBuf> {
    (env.platform == "win32")
        .then(|| windows_app_data(home, env))
        .into_iter()
        .flatten()
        .flat_map(|base| [base.join("kimi"), base.join("Kimi")])
}

/// Metadata for the same configured roots used by discovery. This never walks directories.
pub(crate) fn scan_roots(home: &Path, env: &Environment, source: &str) -> Vec<PathBuf> {
    let normalized;
    let home = if env.preview {
        normalized = normalize(home);
        normalized.as_path()
    } else {
        home
    };
    let local = || env.absolute("LOCALAPPDATA", home.join("AppData/Local"));
    let parents = |paths: Vec<PathBuf>| {
        paths
            .iter()
            .filter_map(|p| p.parent().map(Path::to_path_buf))
            .collect::<Vec<_>>()
    };
    match source {
        "claude" => vec![home.join(".claude/projects")],
        "codex" => vec![home.join(".codex/sessions")],
        "qwen" => vec![home.join(".qwen/usage")],
        "dsh" => vec![home.join(".dsh/storages/session_projcache/sessions")],
        "grok" => vec![home.join(".grok/sessions")],
        "aider" | "cursor" | "trae" => {
            let mut roots = vec![home.into()];
            if source == "cursor" {
                roots.extend(parents(vec![get_cursor_state_db_path(home, env)]));
            }
            if source == "trae" {
                roots.extend(global_bases(
                    home,
                    env,
                    &["TRAE SOLO", "Trae CN", "TRAE SOLO CN", "trae"],
                ));
            }
            roots
        }
        "pi" => vec![home.join(".pi/agent/sessions")],
        "hermes" => parents(vec![get_hermes_db_path(home, env)]),
        "cline" => global_bases(
            home,
            env,
            &["Code", "Code - Insiders", "VSCodium", "Cursor"],
        )
        .iter()
        .flat_map(|p| {
            [
                p.join("saoudrizwan.claude-dev/tasks"),
                p.join("rooveterinaryinc.roo-cline/tasks"),
            ]
        })
        .collect(),
        "gemini" => vec![
            env.absolute("GEMINI_HOME", home.join(".gemini"))
                .join("sessions"),
            home.join(".config/gemini/sessions"),
        ],
        "antigravity" => vec![home.join(ANTIGRAVITY_CONVERSATIONS)],
        "opencode" => {
            let data = xdg_data(home, env).join("opencode");
            match env.get("OPENCODE_DB") {
                Some(":memory:") => vec![],
                Some(value) => parents(vec![if Path::new(value).is_absolute() {
                    value.into()
                } else {
                    data.join(value)
                }]),
                None => vec![data, home.join(".opencode")],
            }
        }
        "kilo" => parents(get_kilo_db_path(home, env).into_iter().collect()),
        "openhands" => {
            if let Some(value) = env.get("OPENHANDS_CONVERSATIONS_DIR") {
                Path::new(value)
                    .is_absolute()
                    .then(|| PathBuf::from(value))
                    .into_iter()
                    .collect()
            } else if let Some(value) = env.get("OPENHANDS_PERSISTENCE_DIR") {
                Path::new(value)
                    .is_absolute()
                    .then(|| Path::new(value).join("conversations"))
                    .into_iter()
                    .collect()
            } else {
                vec![home.join(".openhands/conversations")]
            }
        }
        "goose" => {
            let mut roots = parents(get_goose_db_paths(home, env));
            roots.push(
                env.absolute("GOOSE_PATH_ROOT", home.join(".goose"))
                    .join("data/sessions"),
            );
            roots
        }
        "zed" => {
            let mut roots = parents(vec![get_zed_db_path(home, env)]);
            roots.push(home.join(".local/share/zed/threads"));
            roots
        }
        "continue" => vec![home.join(".continue/sessions")],
        "copilot" => vec![env.absolute("COPILOT_HOME", home.join(".copilot"))],
        "openclaw" => vec![env
            .absolute(
                "OPENCLAW_HOME",
                env.absolute("OPENCLAW_STATE_DIR", home.join(".openclaw")),
            )
            .join("agents")],
        "mimo" => {
            let base = env
                .get("MIMOCODE_HOME")
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .map(|p| p.join("data"))
                .unwrap_or_else(|| xdg_data(home, env).join("mimocode"));
            let mut roots = match env.get("MIMOCODE_DB") {
                Some(":memory:") => vec![],
                Some(value) if !value.is_empty() && base.is_absolute() => {
                    parents(vec![if Path::new(value).is_absolute() {
                        value.into()
                    } else {
                        base.join(value)
                    }])
                }
                _ if base.is_absolute() => vec![base],
                _ => vec![],
            };
            roots.extend(mimo_desktop_root(home, env));
            roots
        }
        "kimi" => vec![
            home.join(".kimi-code/sessions"),
            env.get("KIMI_SHARE_DIR")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".kimi")),
        ]
        .into_iter()
        .chain(kimi_desktop_roots(home, env))
        .chain([home.join(".config/kimi")])
        .filter(|p| p.is_absolute())
        .collect(),
        "minimax" => match env.get("MINIMAX_DATA_DIR").filter(|s| !s.is_empty()) {
            Some(value) => Path::new(value)
                .is_absolute()
                .then(|| PathBuf::from(value))
                .into_iter()
                .collect(),
            None => vec![home.join(".minimax"), home.into()],
        },
        "codebuddy" => {
            let base = match env.platform.as_str() {
                "win32" => local(),
                "darwin" => home.join("Library/Application Support"),
                _ => home.join(".local/share"),
            };
            vec![
                home.join(".codebuddy/projects"),
                home.join(".workbuddy/projects"),
                home.join(".workbuddy-ai/projects"),
                base.join("CodeBuddyExtension/Data"),
            ]
        }
        "zcode" => parents(get_zcode_files(&mut Scan::new(home, env), home, env)),
        "commandcode" => vec![home.join(".commandcode/projects")],
        "anythingllm" => parents(vec![get_anythingllm_db_path(home, env)]),
        _ => vec![],
    }
    .into_iter()
    .map(|p| normalize(&p))
    .collect()
}

fn describe_tool(
    scan: &Scan<'_>,
    home: &Path,
    env: &Environment,
    source: &str,
    files: &[PathBuf],
    errors: &[(PathBuf, ErrorKind)],
) -> StatsDiscoveredTool {
    let mut seen = HashSet::new();
    let roots: Vec<_> = scan_roots(home, env, source)
        .into_iter()
        .filter(|path| seen.insert(path.clone()))
        .collect();
    let mut counts = vec![0; roots.len()];
    for file in files {
        let file = normalize(file);
        // A general search root can contain a more specific candidate directory.
        if let Some((index, _)) = roots
            .iter()
            .enumerate()
            .filter(|(_, dir)| file.starts_with(dir))
            .max_by_key(|(_, dir)| dir.components().count())
        {
            counts[index] += 1;
        }
    }
    let directories: Vec<_> = roots
        .iter()
        .zip(counts)
        .map(|(dir, files)| {
            let exists = scan.allowed(dir).unwrap_or(false) && dir.is_dir();
            let failures = || {
                errors
                    .iter()
                    .filter(|(path, _)| path.starts_with(dir) || dir.starts_with(path))
            };
            let status = if files > 0 {
                "found"
            } else if failures().any(|(_, kind)| *kind == ErrorKind::PermissionDenied) {
                "permission_denied"
            } else if failures().next().is_some() {
                "io_error"
            } else {
                "missing"
            };
            StatsLogDirectory {
                path: dir.to_string_lossy().into_owned(),
                status: status.into(),
                files,
                exists,
            }
        })
        .collect();
    let has_status = |status| directories.iter().any(|dir| dir.status == status);
    let status = if has_status("found") {
        "found"
    } else if has_status("permission_denied") {
        "permission_denied"
    } else if has_status("io_error") {
        "io_error"
    } else {
        "missing"
    };
    StatsDiscoveredTool {
        source: source.into(),
        status: status.into(),
        directories,
        profile: None,
    }
}

pub fn discover_with_env(home: &Path, env: &Environment) -> Result<Vec<(String, Vec<PathBuf>)>> {
    Ok(discover_profiled(home, env, None, false).files)
}

pub(crate) struct Discovery {
    pub files: Vec<(String, Vec<PathBuf>)>,
    pub issues: Vec<DiscoveryIssue>,
    pub tools: Vec<StatsDiscoveredTool>,
}

fn unique_files(scan: &mut Scan<'_>, files: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();
    // Approved difference from Node's ineffective nodir option: only ordinary files enter discovery.
    for file in files
        .into_iter()
        .filter(|file| scan.verified_glob_files.contains(file.as_os_str()) || scan.file(file))
    {
        if !unique
            .iter()
            .any(|p: &PathBuf| p.as_os_str() == file.as_os_str())
        {
            unique.push(file);
        }
    }
    unique
}

pub(crate) fn discover_profiled(
    home: &Path,
    env: &Environment,
    mut source_ns: Option<&mut BTreeMap<String, u64>>,
    include_tools: bool,
) -> Discovery {
    let home = normalize(home);
    let home = home.as_path();
    let mut out = Discovery {
        files: Vec::new(),
        issues: Vec::new(),
        tools: Vec::new(),
    };
    let mut scan = Scan::new(home, env);
    scan.path_errors = include_tools.then(Vec::new);
    let mut started = source_ns.is_some().then(Instant::now);
    let mut add = |scan: &mut Scan<'_>, source: &str, files: Vec<PathBuf>| {
        let unique = unique_files(scan, files);
        if let Some(errors) = scan.path_errors.as_mut().map(std::mem::take) {
            out.tools
                .push(describe_tool(scan, home, env, source, &unique, &errors));
        }
        out.files.push((source.into(), unique));
        let issue = scan.take_issue(source);
        if issue.counts().iter().any(|(_, count)| *count > 0) {
            out.issues.push(issue);
        }
        if let (Some(start), Some(times)) = (started, source_ns.as_deref_mut()) {
            let now = Instant::now();
            times.insert(source.into(), now.duration_since(start).as_nanos() as u64);
            started = Some(now);
        }
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
        let files = glob(&mut scan, &home.join(root), pattern);
        add(&mut scan, source, files);
    }
    add(&mut scan, "hermes", vec![get_hermes_db_path(home, env)]);
    let mut files = Vec::new();
    for base in global_bases(
        home,
        env,
        &["Code", "Code - Insiders", "VSCodium", "Cursor"],
    ) {
        for ext in ["saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline"] {
            files.extend(glob(
                &mut scan,
                &base.join(ext).join("tasks"),
                "*/api_conversation_history.json",
            ));
        }
    }
    add(&mut scan, "cline", files);
    let mut files = glob(
        &mut scan,
        &env.absolute("GEMINI_HOME", home.join(".gemini")),
        "sessions/**/*.{json,jsonl}",
    );
    files.extend(glob(
        &mut scan,
        &home.join(".config/gemini"),
        "sessions/**/*.{json,jsonl}",
    ));
    add(&mut scan, "gemini", files);
    let mut files = vec![get_cursor_state_db_path(home, env)];
    files.extend(glob(&mut scan, home, "*cursor*.csv"));
    add(&mut scan, "cursor", files);
    let files = get_opencode_db_paths(&mut scan, home, env);
    add(&mut scan, "opencode", files);
    add(
        &mut scan,
        "kilo",
        get_kilo_db_path(home, env).into_iter().collect(),
    );
    let root = if let Some(s) = env.get("OPENHANDS_CONVERSATIONS_DIR") {
        Path::new(s).is_absolute().then(|| PathBuf::from(s))
    } else if let Some(s) = env.get("OPENHANDS_PERSISTENCE_DIR") {
        Path::new(s)
            .is_absolute()
            .then(|| Path::new(s).join("conversations"))
    } else {
        Some(home.join(".openhands/conversations"))
    };
    let files = openhands(&mut scan, root);
    add(&mut scan, "openhands", files);
    let mut files = get_goose_db_paths(home, env);
    files.extend(glob(
        &mut scan,
        &env.absolute("GOOSE_PATH_ROOT", home.join(".goose")),
        "data/sessions/sessions.db",
    ));
    add(&mut scan, "goose", files);
    let mut files = vec![get_zed_db_path(home, env)];
    files.extend(glob(&mut scan, home, ".local/share/zed/threads/threads.db"));
    add(&mut scan, "zed", files);
    let files = glob(&mut scan, &home.join(".continue/sessions"), "*.json");
    add(&mut scan, "continue", files);
    let mut files = glob(&mut scan, home, "*trae*.{json,jsonl}");
    for base in global_bases(home, env, &["TRAE SOLO", "Trae CN", "TRAE SOLO CN", "trae"]) {
        files.extend(glob(&mut scan, &base, "**/*trae*.{json,jsonl}"));
    }
    add(&mut scan, "trae", files);
    let files = glob(
        &mut scan,
        &env.absolute("COPILOT_HOME", home.join(".copilot")),
        "{session-store.db,data.db}",
    );
    add(&mut scan, "copilot", files);
    let files = glob(
        &mut scan,
        &env.absolute(
            "OPENCLAW_HOME",
            env.absolute("OPENCLAW_STATE_DIR", home.join(".openclaw")),
        ),
        "agents/*/{sessions,session-sqlite-import-archive}/*.jsonl*",
    );
    add(&mut scan, "openclaw", files);
    let mut files = get_mimocode_db_paths(&mut scan, home, env);
    if let Some(root) = mimo_desktop_root(home, env) {
        files.extend(glob(&mut scan, &root, "mimocode.db"));
    }
    add(&mut scan, "mimo", files);
    let mut files = glob(
        &mut scan,
        &home.join(".kimi-code"),
        "sessions/*/*/agents/*/wire.jsonl",
    );
    let share = env
        .get("KIMI_SHARE_DIR")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".kimi"));
    if share.is_absolute() {
        files.extend(glob(&mut scan, &share, "{sessions,logs}/**/*.{json,jsonl}"));
    }
    if env.platform == "win32" {
        for base in windows_app_data(home, env) {
            files.extend(glob(
                &mut scan,
                &base,
                "{kimi,Kimi}/{sessions,logs}/**/*.{json,jsonl}",
            ));
        }
    }
    files.extend(glob(
        &mut scan,
        &home.join(".config/kimi"),
        "{sessions,logs}/**/*.{json,jsonl}",
    ));
    add(&mut scan, "kimi", files);
    let value = env.get("MINIMAX_DATA_DIR").unwrap_or("");
    let files = if value.is_empty() {
        let mut files = glob(
            &mut scan,
            &home.join(".minimax"),
            "v2/sqlite/runtime-state.sqlite",
        );
        // Node glob processes matched directories using a LIFO work list.
        files.extend(
            glob(&mut scan, home, ".minimax-*/v2/sqlite/runtime-state.sqlite")
                .into_iter()
                .rev(),
        );
        files
    } else if Path::new(value).is_absolute() {
        glob(
            &mut scan,
            Path::new(value),
            "v2/sqlite/runtime-state.sqlite",
        )
    } else {
        Vec::new()
    };
    add(&mut scan, "minimax", files);
    let files = codebuddy(&mut scan, home, env);
    add(&mut scan, "codebuddy", files);
    let files = get_zcode_files(&mut scan, home, env);
    add(&mut scan, "zcode", files);
    let files = glob(&mut scan, &home.join(".commandcode/projects"), "*/*.jsonl")
        .into_iter()
        .filter(|p| {
            let s = p.to_string_lossy();
            !s.ends_with(".checkpoints.jsonl") && !s.ends_with(".prompts.jsonl")
        })
        .collect();
    add(&mut scan, "commandcode", files);
    add(
        &mut scan,
        "anythingllm",
        vec![get_anythingllm_db_path(home, env)],
    );
    let files = glob(&mut scan, &home.join(ANTIGRAVITY_CONVERSATIONS), "*.db");
    add(&mut scan, "antigravity", files);
    out
}
#[cfg(all(test, windows))]
pub fn discover(home: &Path) -> Result<Vec<(String, Vec<PathBuf>)>> {
    discover_with_env(
        home,
        &Environment {
            platform: if cfg!(windows) { "win32" } else { "darwin" }.into(),
            vars: HashMap::new(),
            ..Default::default()
        },
    )
}

#[cfg(test)]
mod e5_tests {
    use super::*;
    use std::time::Duration;

    const CODEX: &str = "**/rollout-*.{jsonl,jsonl.zst}";
    type GlobFn = fn(&mut Scan<'_>, &Path, &str) -> Vec<PathBuf>;

    fn file(root: &Path, relative: &str) {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"").unwrap();
    }

    fn codex_fixture(root: &Path) -> PathBuf {
        let sessions = root.join(".codex/sessions");
        for year in 2025..=2026 {
            for month in 1..=12 {
                for day in 1..=5 {
                    let date = format!("{year}/{month:02}/{day:02}");
                    for index in 0..21 {
                        let suffix = if index == 20 { "jsonl.zst" } else { "jsonl" };
                        file(&sessions, &format!("{date}/rollout-{index}.{suffix}"));
                    }
                    file(&sessions, &format!("{date}/other.jsonl"));
                }
            }
        }
        file(&sessions, ".hidden/rollout-no.jsonl");
        fs::create_dir(sessions.join("empty")).unwrap();
        sessions
    }

    fn measure_codex(
        discover: GlobFn,
        home: &Path,
        sessions: &Path,
    ) -> (Duration, ScanIoCounts, Vec<PathBuf>) {
        let mut scan = Scan::new(home, &Environment::default());
        let start = Instant::now();
        let files = discover(&mut scan, sessions, CODEX);
        let files = unique_files(&mut scan, files);
        let elapsed = start.elapsed();
        assert_eq!(files.len(), 2520);
        assert!(scan
            .take_issue("codex")
            .counts()
            .iter()
            .all(|(_, n)| *n == 0));
        (elapsed, scan.io_counts, files)
    }

    #[test]
    #[ignore = "manual filesystem timing on a synthetic Codex tree"]
    fn e5_codex_discovery_measurement() {
        let home = tempfile::tempdir().unwrap();
        let sessions = codex_fixture(home.path());
        for run in 1..=5 {
            let mut outputs = Vec::new();
            let mut walkers: [(_, GlobFn); 2] = [("old", legacy_glob), ("new", glob)];
            if run % 2 == 0 {
                walkers.reverse();
            }
            for (version, discover) in walkers {
                let (elapsed, counts, files) = measure_codex(discover, home.path(), &sessions);
                println!(
                    "{version} run {run}: read_dir={} metadata={} elapsed_us={}",
                    counts.read_dir,
                    counts.metadata,
                    elapsed.as_micros()
                );
                outputs.push(files);
            }
            assert_eq!(outputs[0], outputs[1]);
        }
    }

    #[test]
    fn e5_codex_lists_each_directory_once() {
        let home = tempfile::tempdir().unwrap();
        let sessions = codex_fixture(home.path());
        let mut scan = Scan::new(home.path(), &Environment::default());
        scan.io_counts.reads_by_dir = Some(HashMap::new());
        let files = glob(&mut scan, &sessions, CODEX);
        assert_eq!(unique_files(&mut scan, files).len(), 2520);
        let dirs = scan.io_counts.reads_by_dir.unwrap();
        assert_eq!(dirs.len(), 148);
        assert_eq!(scan.io_counts.read_dir, dirs.len());
        assert!(dirs.values().all(|&count| count == 1));
        assert_eq!(scan.io_counts.metadata, 2520);
    }

    #[derive(Debug, PartialEq, Eq)]
    struct GlobOutput {
        files: Vec<PathBuf>,
        issues: [(&'static str, usize); 3],
        path_errors: Vec<(PathBuf, ErrorKind)>,
    }

    fn compare_globs(
        home: &Path,
        root: &Path,
        pattern: &str,
        preview: bool,
        partial: &[&str],
    ) -> GlobOutput {
        let run = |discover: GlobFn| {
            let env = Environment {
                preview,
                ..Environment::default()
            };
            let mut scan = Scan::new(home, &env);
            scan.path_errors = Some(Vec::new());
            scan.iteration_errors = partial
                .iter()
                .map(|path| (root.join(path), ErrorKind::Other))
                .collect();
            let files = discover(&mut scan, root, pattern);
            let files = unique_files(&mut scan, files);
            GlobOutput {
                files,
                issues: scan.take_issue("test").counts(),
                path_errors: scan.path_errors.unwrap(),
            }
        };
        let actual = run(glob);
        assert_eq!(
            actual,
            run(legacy_glob),
            "pattern {pattern}, preview {preview}"
        );
        actual
    }

    #[test]
    fn e5_globs_match_legacy_paths_in_order() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path();
        for path in [
            "rollout-2.jsonl",
            "rollout-10.jsonl",
            "rollout-Z.jsonl",
            "rollout-a.JSONL",
            "rollout-1.jsonl.zst",
            "rollout-9.JSONL.ZST",
            "a/deep/more/rollout-5.jsonl",
            "a/rollout-1.jsonl.zst",
            "z/rollout-3.jsonl",
            ".rollout-hidden.jsonl",
            ".hidden/rollout-hidden.jsonl",
            "rollout-7.json",
            "other.jsonl",
            "rollout-dir.jsonl/rollout-child.jsonl",
            "cline/12/api_conversation_history.json",
            "cline/2/api_conversation_history.json",
            "cline/.hidden/api_conversation_history.json",
            "sessions/x/one.jsonl",
            "sessions/zero.json",
            "logs/b.json",
            "logs/a.jsonl",
            "agent/sessions/part.txt/one.jsonl",
            "agent/session-sqlite-import-archive/two.jsonl.zst",
            "data.db",
            "session-store.db",
        ] {
            file(root, path);
        }
        fs::create_dir(root.join("empty")).unwrap();
        for preview in [false, true] {
            for (dir, pattern) in [
                ("", CODEX),
                ("", "**/*.jsonl"),
                ("", "**/.*.jsonl"),
                ("", "rollout-?.json?"),
                ("", "**/rollout-2.jsonl"),
                ("cline", "*/api_conversation_history.json"),
                ("", "sessions/**/*.{json,jsonl}"),
                ("", "{sessions,logs}/**/*.{json,jsonl}"),
                ("", "*/{sessions,session-sqlite-import-archive}/*.jsonl*"),
                ("", "{session-store.db,data.db}"),
                ("", "rollout-*.{jsonl,JSONL}"),
                ("empty", CODEX),
                ("missing", CODEX),
            ] {
                assert!(compare_globs(root, &root.join(dir), pattern, preview, &[])
                    .path_errors
                    .is_empty());
            }
            let files = compare_globs(root, root, CODEX, preview, &[]).files;
            let expected = [
                "rollout-10.jsonl",
                "rollout-2.jsonl",
                "rollout-Z.jsonl",
                "rollout-a.JSONL",
                "a/deep/more/rollout-5.jsonl",
                "rollout-dir.jsonl/rollout-child.jsonl",
                "z/rollout-3.jsonl",
                "rollout-1.jsonl.zst",
                "rollout-9.JSONL.ZST",
                "a/rollout-1.jsonl.zst",
            ];
            assert_eq!(files, expected.map(|path| normalize(&root.join(path))));
        }
    }

    #[test]
    fn e5_glob_replays_partial_errors_at_each_legacy_listing() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path();
        file(root, "sessions/rollout-1.jsonl");
        file(root, "sessions/a/rollout-1.jsonl.zst");
        let sessions = root.join("sessions");
        let partial = compare_globs(root, &sessions, CODEX, false, &["", "a"]);
        let pair = [(&sessions, 2), (&sessions.join("a"), 2)];
        let errors: Vec<_> = pair
            .into_iter()
            .chain(pair)
            .flat_map(|(path, n)| std::iter::repeat_n((normalize(path), ErrorKind::Other), n))
            .collect();
        assert_eq!(partial.path_errors, errors);
        assert_eq!(
            partial.issues,
            [
                ("permission_denied", 0),
                ("io_errors", 0),
                ("unreadable_entries", 8)
            ]
        );
        assert_eq!(partial.files.len(), 2);
        let non_dir = sessions.join("rollout-1.jsonl");
        let failed = compare_globs(root, &non_dir, CODEX, false, &[]);
        assert!(failed.files.is_empty());
        assert_eq!(
            failed.path_errors,
            [(normalize(&non_dir), ErrorKind::NotADirectory)]
        );
        assert_eq!(failed.issues[1], ("io_errors", 1));
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn e5_glob_follows_file_links_only_outside_preview() {
        #[cfg(unix)]
        use std::os::unix::fs::symlink as symlink_file;
        #[cfg(windows)]
        use std::os::windows::fs::symlink_file;

        let fixture = tempfile::tempdir().unwrap();
        let home = fixture.path().join("home");
        let outside = fixture.path().join("outside");
        file(&home, "sessions/rollout-1.jsonl");
        file(&outside, "rollout-outside.jsonl");
        let sessions = home.join("sessions");
        let mut linked_files = Vec::new();
        let target = outside.join("rollout-outside.jsonl");
        let valid = sessions.join("rollout-link.jsonl");
        match symlink_file(&target, &valid) {
            Ok(()) => {
                symlink_file(
                    outside.join("missing"),
                    sessions.join("rollout-broken.jsonl"),
                )
                .unwrap();
                linked_files.push(normalize(&valid));
            }
            #[cfg(windows)]
            Err(error) if error.raw_os_error() == Some(1314) => {
                eprintln!("Windows file symlinks unavailable: {error}");
            }
            Err(error) => panic!("file symlink: {error}"),
        }
        let linked_dir = sessions.join("rollout-folder.jsonl");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &linked_dir).unwrap();
        #[cfg(windows)]
        {
            let output = std::process::Command::new("cmd")
                .args(["/D", "/C", "mklink", "/J"])
                .arg(&linked_dir)
                .arg(&outside)
                .output()
                .unwrap();
            assert!(output.status.success(), "directory junction: {output:?}");
        }

        let ordinary = normalize(&sessions.join("rollout-1.jsonl"));
        let normal = compare_globs(&home, &sessions, CODEX, false, &[]);
        assert_eq!(
            normal.files,
            [vec![ordinary.clone()], linked_files].concat()
        );
        assert!(normal.path_errors.is_empty());
        let preview = compare_globs(&home, &sessions, CODEX, true, &[]);
        assert_eq!(preview.files, [ordinary]);
        assert!(preview.path_errors.is_empty());
        let pattern = "rollout-folder.jsonl/**/rollout-*.jsonl";
        assert_eq!(
            compare_globs(&home, &sessions, pattern, false, &[]).files,
            [normalize(&linked_dir.join("rollout-outside.jsonl"))]
        );
        assert!(compare_globs(&home, &sessions, pattern, true, &[])
            .files
            .is_empty());
    }

    #[cfg(windows)]
    #[test]
    fn e5_globs_match_legacy_under_windows_acl_denials() {
        use std::process::Command;

        struct Denied<'a> {
            path: &'a Path,
            sid: &'a str,
        }
        impl Drop for Denied<'_> {
            fn drop(&mut self) {
                assert!(Command::new("icacls")
                    .arg(self.path)
                    .args(["/remove:d", self.sid])
                    .output()
                    .unwrap()
                    .status
                    .success());
            }
        }
        fn deny<'a>(path: &'a Path, sid: &'a str, rights: &str) -> Denied<'a> {
            let output = Command::new("icacls")
                .arg(path)
                .args(["/deny", &format!("{sid}:({rights})")])
                .output()
                .unwrap();
            assert!(output.status.success(), "{output:?}");
            Denied { path, sid }
        }

        let fixture = tempfile::tempdir().unwrap();
        let home = fixture.path();
        let sessions = home.join("sessions");
        file(&sessions, "denied/rollout-private.jsonl");
        file(&sessions, "rollout-unreadable.jsonl");
        let user = Command::new("whoami")
            .args(["/user", "/fo", "csv", "/nh"])
            .output()
            .unwrap();
        assert!(user.status.success());
        let row = String::from_utf8_lossy(&user.stdout);
        let sid = format!(
            "*{}",
            row.split('"')
                .find(|value| value.starts_with("S-1-"))
                .unwrap()
        );
        let denied_dir = sessions.join("denied");
        let denied_file = sessions.join("rollout-unreadable.jsonl");
        let _dir_acl = deny(&denied_dir, &sid, "RD");
        let _file_acl = deny(&denied_file, &sid, "RD,RA");
        assert_eq!(
            fs::read_dir(&denied_dir).unwrap_err().kind(),
            ErrorKind::PermissionDenied
        );
        assert_eq!(
            fs::File::open(&denied_file).unwrap_err().kind(),
            ErrorKind::PermissionDenied
        );
        for preview in [false, true] {
            let output = compare_globs(home, &sessions, CODEX, preview, &[]);
            assert_eq!(output.issues[0], ("permission_denied", 1));
            assert!(output
                .path_errors
                .contains(&(normalize(&denied_dir), ErrorKind::PermissionDenied)));
            let pattern = "{denied/rollout-private.jsonl,**/rollout-*.jsonl}";
            compare_globs(home, &sessions, pattern, preview, &[]);
        }
        eprintln!(
            "Windows directory listing and file content open both returned PermissionDenied; file metadata: {:?}",
            fs::metadata(&denied_file).map(|metadata| metadata.is_file()).map_err(|error| error.kind())
        );
    }
}

#[cfg(test)]
#[test]
fn s0a_classifies_directory_io_and_partial_iteration() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path();
    let mut scan = Scan::new(root, &Environment::default());
    assert!(scan
        .read_dir(&root.join("absent"), |_| Err::<(), _>(
            ErrorKind::NotFound.into()
        ))
        .is_none());
    assert!(scan
        .read_dir(&root.join("io"), |_| Err::<(), _>(ErrorKind::Other.into()))
        .is_none());
    assert!(scan
        .read_dir(&root.join("io"), |_| Err::<(), _>(ErrorKind::Other.into()))
        .is_none());
    assert!(scan
        .read_dir(&root.join("denied"), |_| Err::<(), _>(
            ErrorKind::PermissionDenied.into()
        ))
        .is_none());
    let (entries, errors) =
        Scan::read_entries([Ok("a"), Err(ErrorKind::Other.into()), Ok("b")].into_iter());
    scan.report_iteration_errors(root, &errors);
    assert_eq!(entries, vec!["a", "b"]);
    let issue = scan.take_issue("claude");
    assert_eq!(
        (
            issue.permission_denied,
            issue.io_errors,
            issue.unreadable_entries
        ),
        (1, 1, 1)
    );
    assert_eq!(
        scan.take_issue("codex").counts(),
        [
            ("permission_denied", 0),
            ("io_errors", 0),
            ("unreadable_entries", 0)
        ]
    );
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
                ..Default::default()
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
            ..Default::default()
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
    use crate::stats::native_golden_path;
    use serde_json::{json, Value};
    fn expand(value: &Value, home: &Path) -> Value {
        if let Some(path) = value.get("home").and_then(Value::as_str) {
            let path = format!(
                "{}{}",
                normalize(&home.join(native_golden_path(path))).display(),
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
                ..Default::default()
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
                let expected_suffixes: Vec<_> = row["identity_suffixes"][source]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|suffix| native_golden_path(suffix.as_str().unwrap()))
                    .collect();
                assert_eq!(
                    suffixes, expected_suffixes,
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
            (
                "antigravity",
                ".gemini/antigravity-cli/conversations/fixture.db",
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
            ..Default::default()
        };
        let found = discover_with_env(home, &env).unwrap();
        assert_eq!(found.len(), super::super::adapters::PARSER_REV.len());
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
            ..Default::default()
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

#[cfg(test)]
#[path = "discovery_s3_tests.rs"]
mod s3_tests;
