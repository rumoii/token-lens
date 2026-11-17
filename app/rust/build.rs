use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn main() {
    println!("cargo:rerun-if-env-changed=TOKEN_LENS_BUILD_COMMIT");
    let commit = std::env::var("TOKEN_LENS_BUILD_COMMIT")
        .ok()
        .or_else(|| git(&["rev-parse", "--short=12", "HEAD"]));
    if let Some(commit) =
        commit.filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_hexdigit()))
    {
        println!("cargo:rustc-env=TOKEN_LENS_BUILD_COMMIT={commit}");
    }
    for reference in std::iter::once("HEAD".to_owned()).chain(git(&["symbolic-ref", "-q", "HEAD"]))
    {
        if let Some(path) = git(&["rev-parse", "--git-path", &reference]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
}
