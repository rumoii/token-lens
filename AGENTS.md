# Repository instructions

Local-first token usage and cost analytics. The main product is the desktop app in `app/` (Flutter UI and Rust core); the legacy Node CLI (`bin/lens.js`, `src/core`) and React/Vite dashboard (`dashboard/`) stay runnable as the rollback path. Read `CLAUDE.md` for the data model and development commands, and `app/README.md` for the desktop app.

## Current work

The desktop rewrite lives in `app/`: Flutter UI and a Rust core, connected through flutter_rust_bridge. Stages D1, D2, D2.5, D2.6, D3.1–D3.5 and D4 are complete, including real-log parity, resource measurements, and a seeded parity run on a copy of the real ledger. The news module has 20 sources refreshed every 30 minutes while the app runs or on demand, item kinds, popularity sorting within each source, and local read and starred state. All 28 adapters (27 ported from the legacy tool plus Antigravity, which exists only in Rust), the statistics queries and their FFI are in Rust. The interface is in Chinese and English, following the system language unless set in Pricing & settings; app strings live in the typed catalog `app/lib/l10n/`, and Rust source and pricing notes carry both languages. The read-only JSON CLI `token-lens-cli` (`app/rust/src/cli.rs`, contract in `specs/cli.md`) and the breakdown export share `app/rust/src/stats/output.rs`, and the full statistics interface is in `app/lib/stats/`. The application ships as `token-lens.exe` / `Token Lens` in zip packages built by `.github/workflows/release.yml`; installers, macOS verification on real hardware and removing the Node/React/CLI code are not scheduled. See `specs/desktop.md` for the rewrite decision, `specs/news.md` for the source/cache contract and `specs/stats.md` for the statistics migration contract. The existing Node/React/wry application stays runnable as the rollback path and is frozen: new adapters and features go into `app/` only, and the legacy tool receives rollback fixes only. The new application targets Windows x64 and macOS arm64; CLI and browser support retire at final replacement. Development and tests set `TOKEN_LENS_PREVIEW_DATA_DIR` to a separate directory; the application never opens `~/.token-lens`. News refresh timing is in `specs/news.md`, section「定时刷新」.

Stages L, N, P, W and M are complete. See `specs/roadmap.md` for pending acceptance, samples, defects and CI status, `specs/ledger-trust.md` for ledger invariants, and `specs/pricing.md` section 9 for pricing. Work one sub-stage at a time and stop for review after each. Any step that changes the real ledger in `~/.token-lens` needs a backup, a dry run on a copy, and the user's confirmation first.

## Red lines

- Do not reintroduce cloud accounts, uploads, public leaderboards, telemetry, Skills management, pets, achievements, or share pages.
- Provider quota calls, IP checks, and service-status probes run only after an explicit user click. No page load, background sync, or timer may trigger them.
- Do not install hooks, plugins, or configuration into other tools' directories.
- Coding agents working in this repository commit locally and never push; the maintainer decides what is pushed. (Human contributors push to their own forks and open pull requests as usual.)
- Missing local runtimes must not trigger an `npx` download.

## Verifying changes

- Run tests against a temporary home and an explicit data directory. Never point a development run at a real home: an installed copy of this tool may be syncing into `~/.token-lens` at the same time.
- `python scripts/desktop-dev.py check` is the desktop aggregate check and the same entry desktop CI calls: Rust format, Clippy and tests, Dart format, analyzer and Flutter tests, third-party notices and lockfiles, all in a fresh temporary directory. `--only rust` or `--only flutter` runs one layer; `python scripts/desktop-dev.py run` starts a debug build on synthetic logs.
- `npm run ci:local` is the aggregate check for the legacy tool: core tests, dashboard tests, build and typecheck. It sets a temporary home, app-data and data directory for every check and removes its temporary directory on completion.
