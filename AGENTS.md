# Repository instructions

Local-first token usage and cost analytics: a Node CLI (`bin/lens.js`, `src/core`) and a React/Vite dashboard (`dashboard/`). Read `CLAUDE.md` for the data model and development commands.

## Current work

The desktop rewrite lives in `app/`: Flutter UI and a Rust core, connected through flutter_rust_bridge. Stages D1, D2 and D2.5 are complete. The news preview covers 19 sources, item kinds, and popularity sorting within each source. The next stage is D3, migrating statistics. See `specs/desktop.md` for the rewrite decision and `specs/news.md` for the source/cache contract. The existing Node/React/wry application remains the usable release until statistics migration is accepted. The new application targets Windows x64 and macOS arm64; CLI and browser support retire at final replacement. Use a separate preview data directory; the preview never reads or migrates the real ledger. News requests run only after a refresh click.

Stages L, N, P, W and M are complete. See `specs/roadmap.md` for pending acceptance, samples, defects and CI status, `specs/ledger-trust.md` for ledger invariants, and `specs/pricing.md` section 9 for pricing. Work one sub-stage at a time and stop for review after each. Any step that changes the real ledger in `~/.token-lens` needs a backup, a dry run on a copy, and the user's confirmation first.

## Red lines

- Do not reintroduce cloud accounts, uploads, public leaderboards, telemetry, Skills management, pets, achievements, or share pages.
- Provider quota calls, IP checks, and service-status probes run only after an explicit user click. No page load, background sync, or timer may trigger them.
- Do not install hooks, plugins, or configuration into other tools' directories.
- Commits stay local. Do not push.
- Missing local runtimes must not trigger an `npx` download.

## Verifying changes

- Run tests against a temporary home and an explicit data directory. Never point a development run at a real home: an installed copy of this tool may be syncing into `~/.token-lens` at the same time.
- `npm run ci:local` is the aggregate check: core tests, dashboard tests, build and typecheck. It sets a temporary home, app-data and data directory for every check and removes its temporary directory on completion.
