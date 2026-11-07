use super::Result;
use std::path::{Component, Path, PathBuf};

pub fn discover(home: &Path) -> Result<Vec<(String, Vec<PathBuf>)>> {
    // Node discovery uses path.resolve. Normalize discovery roots lexically;
    // adapter identity inputs themselves are never resolved or rewritten.
    #[cfg(windows)]
    let native_home = PathBuf::from(home.to_string_lossy().replace('/', "\\"));
    #[cfg(not(windows))]
    let native_home = home.to_path_buf();
    let mut home = PathBuf::new();
    for component in native_home.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                home.pop();
            }
            _ => home.push(component.as_os_str()),
        }
    }
    fn walk(directory: &Path, source: &str, files: &mut Vec<PathBuf>) -> Result<()> {
        let entries = match std::fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error.into()),
        };
        let mut entries = entries.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let kind = entry.file_type()?;
            let path = entry.path();
            if kind.is_dir() {
                walk(&path, source, files)?;
            } else if path.is_file() {
                // Approved D3 difference: matching directories are not log files.
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if (source == "claude" && name.ends_with(".jsonl"))
                    || (source == "codex"
                        && name.starts_with("rollout-")
                        && (name.ends_with(".jsonl") || name.ends_with(".jsonl.zst")))
                {
                    files.push(path);
                }
            }
        }
        Ok(())
    }
    let mut output = Vec::new();
    for (source, root) in [
        ("claude", home.join(".claude").join("projects")),
        ("codex", home.join(".codex").join("sessions")),
    ] {
        let mut files = Vec::new();
        // safeGlob treats a failed scan as an empty result for that source.
        if walk(&root, source, &mut files).is_err() {
            files.clear();
        }
        output.push((source.into(), files));
    }
    Ok(output)
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
