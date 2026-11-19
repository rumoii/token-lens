"""Run Token Lens with synthetic desktop data or execute the desktop CI checks."""

import argparse
from contextlib import nullcontext
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from desktop_env import isolated_environment, seed_preferences_and_news


REPO = Path(__file__).resolve().parents[1]
APP = REPO / "app"
LOCKS = ("pubspec.lock", "rust/Cargo.lock")


def stage(name, command, environment, hint):
    print(f"\n== {name} ==", flush=True)
    try:
        executable = shutil.which(command[0], path=environment["PATH"])
        if executable is None:
            raise FileNotFoundError(f"{command[0]} was not found on PATH")
        subprocess.run([executable, *command[1:]], cwd=APP, env=environment, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"{name} failed ({error}). {hint}") from None


def check(environment, only):
    lock_check = ["git", "diff", "--exit-code", "HEAD", "--", *LOCKS]
    lock_hint = "Inspect app/pubspec.lock and app/rust/Cargo.lock."
    stage("Check lockfiles", lock_check, environment, lock_hint)
    if only != "flutter":
        rust = ["--manifest-path", "rust/Cargo.toml"]
        stage("Rust format", ["cargo", "fmt", *rust, "--", "--check"],
              environment, "Run cargo fmt from app/rust.")
        stage("Rust clippy", ["cargo", "clippy", *rust, "--locked", "--all-targets", "--", "-D", "warnings"],
              environment, "Fix the first Clippy diagnostic above.")
        # Keep test cases from competing for the process-wide diagnostics writer lock.
        stage("Rust tests", ["cargo", "test", *rust, "--locked", "--", "--test-threads=1"],
              environment, "See the failing Rust test and assertion above.")
    if only != "rust":
        stage("Dart format", ["dart", "format", "--output=none", "--set-exit-if-changed",
                              "lib", "test", "hook", "../scripts/generate-desktop-notices.dart"],
              environment, "Run dart format on the files listed above.")
        stage("Flutter analyze", ["flutter", "analyze", "--no-pub"],
              environment, "Resolve locked Flutter packages first, then inspect the analyzer diagnostics.")
        stage("Flutter tests", ["flutter", "test", "--no-pub"],
              environment, "See the failing Flutter test or native build diagnostic above.")
    if only is None:
        stage("Third-party notices", ["dart", "--packages=.dart_tool/package_config.json",
                                      "../scripts/generate-desktop-notices.dart", "--check"],
              environment, "Check the locked Flutter packages and Cargo caches for both desktop targets.")
    stage("Check lockfiles after checks", lock_check, environment, lock_hint)


def run_preview(environment):
    platform = {"win32": "windows", "darwin": "macos"}.get(sys.platform)
    if platform is None:
        raise SystemExit("Desktop preview requires Windows or macOS.")
    data = Path(environment["TOKEN_LENS_PREVIEW_DATA_DIR"])
    home = Path(environment["TOKEN_LENS_PREVIEW_HOME"])
    seed_preferences_and_news(data)
    fixture = REPO / "test/fixtures/parity/claude.jsonl"
    with fixture.open(encoding="utf-8") as source:
        record = json.loads(source.readline())
    # Keep the fixture visible in the default date ranges year-round.
    record["timestamp"] = datetime.now(timezone.utc).isoformat()
    log = home / ".claude/projects/preview/usage.jsonl"
    log.parent.mkdir(parents=True)
    log.write_text(json.dumps(record) + "\n", encoding="utf-8")
    stage("Run desktop preview", ["flutter", "run", "--no-pub", "-d", platform],
          environment, "Resolve locked Flutter packages and check the desktop build output above.")


def expose_macos_toolchain(environment):
    # Flutter's native-assets hook passes HOME but drops CARGO_HOME and RUSTUP_HOME.
    # Rustup on macOS can find the installed toolchain at these default locations.
    home = Path(environment["HOME"])
    for name, folder in (("CARGO_HOME", ".cargo"), ("RUSTUP_HOME", ".rustup")):
        cache = Path(environment[name]).resolve()
        if not cache.is_dir():
            raise SystemExit(f"Installed toolchain directory missing: {cache}")
        (home / folder).symlink_to(cache, target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="action", required=True)
    preview = subcommands.add_parser("run", help="launch with a synthetic Claude log")
    preview.add_argument("--keep", action="store_true", help="keep the temporary profile after exit")
    checks = subcommands.add_parser("check", help="run the same checks as desktop CI")
    checks.add_argument("--only", choices=("rust", "flutter"))
    args = parser.parse_args()
    keep = getattr(args, "keep", False)
    prefix = "token-lens-desktop-"
    folder = nullcontext(tempfile.mkdtemp(prefix=prefix)) if keep else tempfile.TemporaryDirectory(prefix=prefix)
    with folder as temporary:
        root = Path(temporary).resolve()
        print(f"Isolated desktop profile: {root}", flush=True)
        environment = isolated_environment(root)
        if sys.platform == "darwin":
            expose_macos_toolchain(environment)
        try:
            if args.action == "run":
                run_preview(environment)
            else:
                check(environment, args.only)
        finally:
            if keep:
                print(f"Kept desktop profile: {root}", flush=True)


if __name__ == "__main__":
    main()
