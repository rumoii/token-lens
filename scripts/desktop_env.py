"""Synthetic desktop profiles shared by development checks and release smoke tests."""

import json
import os
from pathlib import Path
import time


CLIENT_OVERRIDES = (
    "OPENCODE_DB", "KILO_DB", "MIMOCODE_HOME", "MIMOCODE_DB",
    "MIMOCODE_DISABLE_CHANNEL_DB", "ZCODE_DATA_BASE_DIR", "ZCODE_SESSION_DB_PATH",
    "ZCODE_SESSION_DB", "GEMINI_HOME", "OPENHANDS_CONVERSATIONS_DIR",
    "OPENHANDS_PERSISTENCE_DIR", "GOOSE_PATH_ROOT", "COPILOT_HOME",
    "OPENCLAW_HOME", "OPENCLAW_STATE_DIR", "KIMI_SHARE_DIR", "MINIMAX_DATA_DIR",
    "TOKEN_LENS_DATA_DIR", "DB_PATH",
)

# Disable the registry entries for long-running previews as well as startup.
NEWS_SOURCES = (
    "openai", "deepmind", "google-ai", "deepseek", "anthropic-api", "openai-api",
    "gh-release:anthropics/claude-code", "gh-release:openai/codex",
    "gh-release:google-gemini/gemini-cli", "gh-release:anomalyco/opencode",
    "gh-release:earendil-works/pi", "gh-release:ollama/ollama", "github-new",
    "hf-models", "hf-spaces", "hf-papers", "hn-ai", "qbitai", "aibase", "aihot",
)


def isolated_environment(root):
    environment = os.environ.copy()
    # Preserve the SDK caches before replacing the home used by the app and tests.
    user_home = Path.home()
    pub_cache_base = Path(environment.get("LOCALAPPDATA", user_home)) if os.name == "nt" else user_home
    for name, path in {
        "CARGO_HOME": user_home / ".cargo",
        "RUSTUP_HOME": user_home / ".rustup",
        "PUB_CACHE": pub_cache_base / ("Pub/Cache" if os.name == "nt" else ".pub-cache"),
    }.items():
        environment.setdefault(name, str(path))
    for name in CLIENT_OVERRIDES:
        environment.pop(name, None)
    for name, child in {
        "TOKEN_LENS_PREVIEW_DATA_DIR": "data",
        "TOKEN_LENS_PREVIEW_HOME": "home",
        "HOME": "home",
        "USERPROFILE": "home",
        "APPDATA": "home/AppData/Roaming",
        "LOCALAPPDATA": "home/AppData/Local",
        "XDG_DATA_HOME": "home/.local/share",
        "TEMP": ".",
        "TMP": ".",
        "TMPDIR": ".",
    }.items():
        directory = root / child
        directory.mkdir(parents=True, exist_ok=True)
        environment[name] = str(directory)
    environment.update(FLUTTER_SUPPRESS_ANALYTICS="true", DART_SUPPRESS_ANALYTICS="true",
                       RUSTUP_AUTO_INSTALL="0")
    return environment


def seed_preferences_and_news(data):
    (data / "ui-preferences.json").write_text(json.dumps({
        "onboarded": True,
        "autoCheckUpdates": False,
    }), encoding="utf-8")
    (data / "news-cache.json").write_text(json.dumps({
        "version": 2,
        "disabled": NEWS_SOURCES,
        "sources": {"openai": {"items": [], "last_success_ms": int(time.time() * 1000)}},
    }), encoding="utf-8")
