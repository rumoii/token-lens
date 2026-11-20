"""Run Token Lens with synthetic desktop data or execute the desktop CI checks."""

import argparse
from contextlib import nullcontext
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from desktop_demo import generate_logs
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
        check_demo(environment)
    if only != "rust":
        stage("Dart format", ["dart", "format", "--output=none", "--set-exit-if-changed",
                              "lib", "test", "hook", "../scripts/generate-desktop-notices.dart"],
              environment, "Run dart format on the files listed above.")
        stage("Flutter analyze", ["flutter", "analyze", "--no-pub"],
              environment, "Resolve locked Flutter packages first, then inspect the analyzer diagnostics.")
        test_environment = environment
        if sys.platform == "darwin":
            # Flutter tester builds a dylib here. FRB otherwise looks for an app framework.
            test_environment = {
                **environment,
                "FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR": str(APP / "build/native_assets/macos"),
            }
        stage("Flutter tests", ["flutter", "test", "--no-pub"],
              test_environment, "See the failing Flutter test or native build diagnostic above.")
    if only is None:
        stage("Third-party notices", ["dart", "--packages=.dart_tool/package_config.json",
                                      "../scripts/generate-desktop-notices.dart", "--check"],
              environment, "Check the locked Flutter packages and Cargo caches for both desktop targets.")
    stage("Check lockfiles after checks", lock_check, environment, lock_hint)


def launch_preview(environment, label):
    platform = {"win32": "windows", "darwin": "macos"}.get(sys.platform)
    if platform is None:
        raise SystemExit("Desktop preview requires Windows or macOS.")
    stage(label, ["flutter", "run", "--no-pub", "-d", platform],
          environment, "Resolve locked Flutter packages and check the desktop build output above.")


def run_preview(environment):
    data = Path(environment["TOKEN_LENS_PREVIEW_DATA_DIR"])
    home = Path(environment["TOKEN_LENS_PREVIEW_HOME"])
    seed_preferences_and_news(data)
    fixture = REPO / "app/rust/tests/fixtures/parity/claude.jsonl"
    with fixture.open(encoding="utf-8") as source:
        record = json.loads(source.readline())
    # Keep the fixture visible in the default date ranges year-round.
    record["timestamp"] = datetime.now(timezone.utc).isoformat()
    log = home / ".claude/projects/preview/usage.jsonl"
    log.parent.mkdir(parents=True)
    log.write_text(json.dumps(record) + "\n", encoding="utf-8")
    launch_preview(environment, "Run desktop preview")


def demo_output(path):
    requested = path.expanduser().absolute()
    home = Path.home()
    roaming = Path(os.environ.get("APPDATA", home / "AppData/Roaming"))
    protected = [home / ".token-lens", roaming / "Token Lens"]
    if sys.platform == "darwin":
        protected.append(home / "Library/Application Support/io.github.rumoii.token-lens")
    root = requested.resolve()
    if any(requested.is_relative_to(directory) or root.is_relative_to(directory.resolve())
           for directory in protected):
        raise SystemExit("Demo output must be outside Token Lens user data directories.")
    if root.exists() and (not root.is_dir() or any(root.iterdir())):
        raise SystemExit("Demo output must be a new or empty directory.")
    # Claim the data directory before isolated_environment opens the profile.
    (root / "data").mkdir(parents=True)
    return root


def demo_cli(environment, *args):
    command = ["cargo", "run", "--manifest-path", "rust/Cargo.toml", "--locked", "--offline",
               "--quiet", "--bin", "token-lens-cli", "--",
               "--data-dir", environment["TOKEN_LENS_PREVIEW_DATA_DIR"], *args]
    try:
        result = subprocess.run(command, cwd=APP, env=environment, check=True,
                                capture_output=True, encoding="utf-8")
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Demo CLI {args[0]} failed ({error.returncode}):\n{error.stderr}") from None
    except OSError as error:
        raise SystemExit(f"Could not run demo CLI: {error}") from None
    return json.loads(result.stdout)["data"]


def sync_demo(environment):
    data = Path(environment["TOKEN_LENS_PREVIEW_DATA_DIR"])
    seed_preferences_and_news(data)
    result = demo_cli(environment, "sync")
    if result["rejected"] != 0:
        raise SystemExit(f"Demo sync rejected {result['rejected']} records.")
    print(f"Demo sync: inserted={result['inserted']}, rejected={result['rejected']}", flush=True)


def run_demo(environment, launch):
    home = Path(environment["TOKEN_LENS_PREVIEW_HOME"])
    generate_logs(home, date.today())
    sync_demo(environment)
    print(f"Logs: {home}\nLedger: {Path(environment['TOKEN_LENS_PREVIEW_DATA_DIR']) / 'ledger.db'}",
          flush=True)
    if launch:
        launch_preview(environment, "Run desktop demo")


def check_demo(environment):
    print("\n== Desktop demo data ==", flush=True)
    with tempfile.TemporaryDirectory(dir=environment["TEMP"], prefix="demo-") as temporary:
        root = Path(temporary)
        demo = isolated_environment(root / "first")
        home = Path(demo["TOKEN_LENS_PREVIEW_HOME"])
        peer = root / "second"
        today = date.today()
        expected = generate_logs(home, today)
        generate_logs(peer, today)

        def snapshot(path):
            return {entry.relative_to(path): entry.read_bytes()
                    for entry in path.rglob("*") if entry.is_file()}

        if snapshot(home) != snapshot(peer):
            raise SystemExit("Desktop demo logs differ between two runs for the same date.")
        print("Demo log paths and bytes match on both runs.", flush=True)
        sync_demo(demo)
        sources = demo_cli(demo, "sources")["sources"]
        actual = {source["tool"]: source["record_count"] for source in sources if source["record_count"]}
        records = {tool: totals.records for tool, totals in expected.items()}
        if actual != records:
            raise SystemExit(f"Demo source records: expected {records}, got {actual}.")
        for tool, totals in expected.items():
            summary = demo_cli(demo, "summary", "--period", "all", "--tool", tool)
            if summary["total_tokens"] != totals.tokens:
                raise SystemExit(f"Demo {tool} tokens: expected {totals.tokens}, got {summary['total_tokens']}.")
            print(f"{tool}: {totals.sessions} sessions, {totals.records} records, {totals.tokens} tokens",
                  flush=True)


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
    demo = subcommands.add_parser("demo", help="sync synthetic usage from five tools and launch the desktop")
    demo.add_argument("--keep", action="store_true", help="keep the temporary profile after exit")
    demo.add_argument("--out", type=Path, help="write home/ and data/ledger.db here without launching")
    checks = subcommands.add_parser("check", help="run the same checks as desktop CI")
    checks.add_argument("--only", choices=("rust", "flutter"))
    args = parser.parse_args()
    keep = getattr(args, "keep", False)
    out = getattr(args, "out", None)
    prefix = "token-lens-desktop-"
    if out is not None:
        folder = nullcontext(demo_output(out))
    elif keep:
        folder = nullcontext(tempfile.mkdtemp(prefix=prefix))
    else:
        folder = tempfile.TemporaryDirectory(prefix=prefix)
    with folder as temporary:
        root = Path(temporary).resolve()
        print(f"Isolated desktop profile: {root}", flush=True)
        environment = isolated_environment(root)
        if sys.platform == "darwin" and out is None:
            expose_macos_toolchain(environment)
        try:
            if args.action == "run":
                run_preview(environment)
            elif args.action == "demo":
                run_demo(environment, launch=out is None)
            else:
                check(environment, args.only)
        finally:
            if keep:
                print(f"Kept desktop profile: {root}", flush=True)


if __name__ == "__main__":
    main()
