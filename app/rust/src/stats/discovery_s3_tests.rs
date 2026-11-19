use super::*;

#[test]
fn tools_follow_scan_roots_on_each_platform() {
    let root = tempfile::tempdir().unwrap();
    let home = normalize(root.path());
    let cline_file =
        "Code/User/globalStorage/saoudrizwan.claude-dev/tasks/s/api_conversation_history.json";
    let claude = home.join(".claude/projects/s/example.jsonl");
    fs::create_dir_all(claude.parent().unwrap()).unwrap();
    fs::write(&claude, "{}").unwrap();
    for (platform, app_data) in [
        ("win32", "AppData/Roaming"),
        ("darwin", "Library/Application Support"),
    ] {
        let file = home.join(app_data).join(cline_file);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "{}").unwrap();
        let env = Environment {
            platform: platform.into(),
            ..Environment::default().preview()
        };
        let outcome = discover_profiled(&home, &env, None, true);
        assert_eq!(
            outcome.tools.len(),
            crate::stats::adapters::PARSER_REV.len()
        );
        for (tool, (id, files)) in outcome.tools.iter().zip(&outcome.files) {
            assert_eq!(&tool.source, id);
            let mut seen = HashSet::new();
            let expected: Vec<_> = scan_roots(&home, &env, id)
                .into_iter()
                .filter(|path| seen.insert(path.clone()))
                .collect();
            let actual: Vec<_> = tool
                .directories
                .iter()
                .map(|dir| PathBuf::from(&dir.path))
                .collect();
            assert_eq!(actual, expected, "{platform}: {id}");
            assert!(actual.iter().all(|path| path.starts_with(&home)));
            assert_eq!(
                tool.directories.iter().map(|dir| dir.files).sum::<i64>(),
                files.len() as i64,
                "{platform}: {id}"
            );
            if platform == "darwin" {
                assert!(actual
                    .iter()
                    .all(|path| !path.starts_with(home.join("AppData"))));
            }
        }
    }
}

#[test]
fn four_directory_states_and_tool_precedence_use_scan_errors() {
    let home = tempfile::tempdir().unwrap();
    let env = Environment {
        platform: "win32".into(),
        ..Environment::default()
    };
    let roots = scan_roots(home.path(), &env, "cline");
    let mut scan = Scan::new(home.path(), &env);
    scan.path_errors = Some(Vec::new());
    let file = roots[0].join("s/api_conversation_history.json");
    scan.read_dir::<()>(&roots[1], |_| Err(ErrorKind::PermissionDenied.into()));
    scan.read_dir::<()>(&roots[2], |_| Err(ErrorKind::Other.into()));
    let errors = scan.path_errors.as_deref().unwrap();
    let tool = describe_tool(&scan, home.path(), &env, "cline", &[file], errors);
    assert_eq!(tool.status, "found");
    assert_eq!(
        tool.directories
            .iter()
            .take(4)
            .map(|dir| dir.status.as_str())
            .collect::<Vec<_>>(),
        ["found", "permission_denied", "io_error", "missing"]
    );
    for (sample, status) in [
        (errors, "permission_denied"),
        (&errors[1..], "io_error"),
        (&[], "missing"),
    ] {
        assert_eq!(
            describe_tool(&scan, home.path(), &env, "cline", &[], sample).status,
            status
        );
    }
}
