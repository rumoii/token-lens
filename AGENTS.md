# Repository instructions

Local-first token usage and cost analytics: a Node CLI (`bin/lens.js`, `src/core`) and a React/Vite dashboard (`dashboard/`). Read `CLAUDE.md` for the data model and development commands.

## Current work

Stages L (L0–L6), N (N1–N5), P (P0–P4 and the pricing page), W (W1–W4 on Windows), and macOS arm64 (M0–M4) are complete. No development stage is in progress; the user selects the next task. See `specs/roadmap.md` for pending Windows/R5 acceptance and real client samples, deferred R6 and adapters, known defects, and CI status. `specs/ledger-trust.md` lists each L step with file locations and acceptance checks; `specs/pricing.md` section 9 defines the pricing contract; `specs/desktop.md` records the desktop constraints and the chosen shell: a Rust + wry window around the unchanged Node kernel, shipped as a self-extracting portable exe on Windows and a dmg on macOS arm64. Work one sub-stage at a time and stop for review after each. Any step that changes the real ledger in `~/.token-lens` needs a backup, a dry run on a copy, and the user's confirmation first.

## Red lines

- Do not reintroduce cloud accounts, uploads, public leaderboards, telemetry, Skills management, pets, achievements, or share pages.
- Provider quota calls, IP checks, and service-status probes run only after an explicit user click. No page load, background sync, or timer may trigger them.
- Do not install hooks, plugins, or configuration into other tools' directories.
- Commits stay local. Do not push.
- Missing local runtimes must not trigger an `npx` download.

## Verifying changes

- Run tests against a temporary home and an explicit data directory. Never point a development run at a real home: an installed copy of this tool may be syncing into `~/.token-lens` at the same time.
- `npm run ci:local` is the aggregate check: core tests, dashboard tests, build and typecheck. It sets a temporary home, app-data and data directory for every check and removes its temporary directory on completion.
