"""Launch a release app with synthetic logs and verify ingestion through read-only SQLite."""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time


SESSION = "token-lens-desktop-smoke"


def ingestion_result(database, empty_home):
    if not database.is_file():
        return None
    # Keep WAL visible; immutable=1 would hide records not yet checkpointed.
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.2)) as connection:
        connection.execute("PRAGMA query_only=ON")
        if empty_home:
            synced = connection.execute(
                "SELECT EXISTS (SELECT 1 FROM ingest_runs WHERE status='ok' AND attempted=0) "
                "AND NOT EXISTS (SELECT 1 FROM usage_records)"
            ).fetchone()[0]
            return "empty-home sync completed with 0 usage records" if synced else None
        rows = connection.execute(
            "SELECT count(*) FROM usage_records WHERE source='claude' AND session_id=? "
            "AND active=1 AND input_tokens=7 AND output_tokens=3",
            (SESSION,),
        ).fetchone()[0]
        return f"{rows} synthetic Claude usage record(s)" if rows else None


def smoke(executable, timeout, empty_home):
    with tempfile.TemporaryDirectory(prefix="token-lens-smoke-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        root = Path(temporary).resolve()
        environment = os.environ.copy()
        # Remove every client override used by Rust discovery before assigning the synthetic roots.
        for key in [
            "OPENCODE_DB", "KILO_DB", "MIMOCODE_HOME", "MIMOCODE_DB",
            "MIMOCODE_DISABLE_CHANNEL_DB", "ZCODE_DATA_BASE_DIR", "ZCODE_SESSION_DB_PATH",
            "ZCODE_SESSION_DB", "GEMINI_HOME", "OPENHANDS_CONVERSATIONS_DIR",
            "OPENHANDS_PERSISTENCE_DIR", "GOOSE_PATH_ROOT", "COPILOT_HOME",
            "OPENCLAW_HOME", "OPENCLAW_STATE_DIR", "KIMI_SHARE_DIR", "MINIMAX_DATA_DIR",
            "TOKEN_LENS_DATA_DIR", "DB_PATH",
        ]:
            environment.pop(key, None)
        for variable, child in {
            "TOKEN_LENS_PREVIEW_DATA_DIR": "data",
            "TOKEN_LENS_PREVIEW_HOME": "home",
            "HOME": "home",
            "USERPROFILE": "home",
            "APPDATA": "roaming",
            "LOCALAPPDATA": "local",
            "XDG_DATA_HOME": "xdg",
        }.items():
            directory = root / child
            directory.mkdir(exist_ok=True)
            environment[variable] = str(directory)
        data = root / "data"
        # Smoke doesn't click through onboarding, so opt into startup sync and disable update requests.
        (data / "ui-preferences.json").write_text(json.dumps({
            "onboarded": True,
            "autoCheckUpdates": False,
        }), encoding="utf-8")
        if not empty_home:
            log = root / "home/.claude/projects/smoke/usage.jsonl"
            log.parent.mkdir(parents=True)
            log.write_text(json.dumps({
                "sessionId": SESSION,
                "timestamp": "2026-01-15T12:00:00Z",
                "message": {
                    "id": "msg_token_lens_desktop_smoke",
                    "model": "synthetic-smoke-model",
                    "usage": {
                        "input_tokens": 7, "output_tokens": 3,
                        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                    },
                },
            }) + "\n", encoding="utf-8")
        # A fresh successful cache keeps this ingestion check offline at startup.
        (data / "news-cache.json").write_text(json.dumps({
            "version": 2,
            "disabled": [],
            "sources": {"openai": {"items": [], "last_success_ms": int(time.time() * 1000)}},
        }), encoding="utf-8")
        process = subprocess.Popen([str(executable)], cwd=executable.parent, env=environment)
        started = time.monotonic()
        missing = "successful empty-home sync absent" if empty_home else "synthetic usage record absent"
        try:
            while True:
                status = process.poll()
                if status is not None:
                    raise RuntimeError(f"Application exited early with status {status}.")
                try:
                    result = ingestion_result(data / "ledger.db", empty_home)
                    last_error = missing
                except sqlite3.OperationalError as error:
                    result = None
                    last_error = str(error)
                elapsed = time.monotonic() - started
                if result is not None and elapsed >= 20:
                    # Check again after the read; an early process exit must never pass.
                    if process.poll() is not None:
                        raise RuntimeError("Application exited during the ingestion check.")
                    print(f"PASS: {result}; application stayed running for {elapsed:.1f}s.")
                    return
                if elapsed >= timeout:
                    raise RuntimeError(f"Ingestion check timed out after {timeout}s ({last_error}).")
                time.sleep(min(0.25, timeout - elapsed))
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="Release executable, or the binary inside the macOS .app")
    parser.add_argument("--empty-home", action="store_true", help="Omit the synthetic log and verify a successful sync with zero records")
    parser.add_argument("--timeout", type=int, default=60, help="Ingestion deadline in seconds (20–60; default 60)")
    args = parser.parse_args()
    if not 20 <= args.timeout <= 60:
        parser.error("--timeout must be between 20 and 60 seconds")
    executable = args.executable.resolve(strict=True)
    if not executable.is_file():
        parser.error("executable must be a file")
    smoke(executable, args.timeout, args.empty_home)


if __name__ == "__main__":
    main()
