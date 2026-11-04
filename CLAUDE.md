# Token Lens

ESM modules under `src/core` (the root `package.json` declares `commonjs`; `src/core/package.json` overrides to `module`). `bin/lens.js` loads `src/core/cli.js`. The dashboard is a React/Vite app in `dashboard/`, built to `dashboard/dist` and served by `lens serve` on loopback only.

## Current work

The remaining stage L work (ledger accuracy), then stage N (more clients), stage P (pricing: wider catalog, long-context tiers, peak/off-peak, local models) and stage W (desktop app: Windows, then macOS arm64); R5 and R6 are deferred until after W. See `specs/roadmap.md`, `specs/ledger-trust.md`, `specs/pricing.md` (section 9) and `specs/desktop.md`. Stop for review after each sub-stage; never change the real ledger without a backup, a dry run on a copy, and the user's confirmation.

## Development

```sh
npm ci
npm ci --prefix dashboard
npm run dashboard:build
npm run ci:local
```

`npm test` runs `test/core/*.test.js`; `npm run dashboard:test` runs the complete Vitest suite. Both use `scripts/verify-local.mjs` to set a temporary home, app-data, data directory and temp directory, remove inherited `DB_PATH`, and clean up on completion. Every test that opens a database or a server still uses a temporary directory or `:memory:`.

Run commands with an explicit `--data-dir` (or `TOKEN_LENS_DATA_DIR`) when pointing at anything but a test directory.

## Checks

| Command | Scope |
|---|---|
| `npm run dashboard:test` | Complete dashboard behavior and utility tests, in an isolated environment. |
| `npm run ci:local` | Core tests, dashboard tests, build and typecheck, in an isolated environment. |

## Data flow

```
discovery → adapters → ledger → queries → /api/v1 → dashboard
```

- `src/core/paths.js` is the single authority for the data directory: `--data-dir`, then `TOKEN_LENS_DATA_DIR`, then `DB_PATH`, then `~/.token-lens`. Conflicts raise an error instead of guessing.
- `src/core/db/open.js` opens the ledger and migrates it. Importing a module never creates a directory or a database.
- `src/core/db/ledger.js` owns the connection and exposes `ledger.read` and `ledger.write`; only the owner closes the shared connection.
- `src/core/db/read.js` owns aggregate queries, filters, time buckets, session and source queries. `src/core/db/write.js` owns usage ingestion, run records, legacy imports and repricing transactions, with pricing supplied by the caller.
- `src/core/db/legacy.js` copies rows from an older `data.db` into `legacy_records`, read-only, and never feeds them into the current totals.
- `src/core/api/v1/` groups usage, session, source/discovery and pricing/health services. They receive query capabilities; `common.js` owns shared filters and response formatting. Each router owns its discovery cache.
- `src/core/pricing/engine.js` computes totals and integer parts through `priceRecord`; `costOf` preserves the stored-price interface. Breakdown streams priced rows through `ledger.read.costRows` and exposes parts only when each stored version and amount matches; it never rewrites the ledger or assigns a difference to another part.

## Ledger contract

`usage_records`:

| Column | Meaning |
|---|---|
| `record_key` | Stable identity. Never contains token counts. Same key means same record. |
| `content_hash` | Detects that the same record now reports something different: kind, model, the four token fields, `observed_at`, `ended_at`, `session_id`, the cache-write split and non-NULL `provider`. NULL provider adds no input or separator, preserving the v4 hash exactly. Project labels are not part of it; a newly recognised project is relabelled in place. |
| `kind` | `event` (one request) or `cumulative` (a session snapshot that gets rewritten). |
| `ended_at` | Last activity a `cumulative` snapshot covers; `observed_at` is when the session started. `NULL` means unknown. A snapshot whose start and end fall in the same time bucket is counted in that bucket; otherwise it goes to `unallocated`. Added in schema v3; filled on the next collection. |
| `input_tokens` … `cache_write_tokens` | `NULL` means unknown. Unknown is not zero. |
| `provider` | Provider ID explicitly written in the log; `NULL` means unknown. Added in schema v5 without backfilling old rows. Never inferred from model names, paths or the client. Non-NULL values enter the content hash, so re-reading a log that supplies one updates the row once. Local IDs in `pricing/catalog.js` are matched case-insensitively and priced at zero, with four zero parts and `price_source = local:<lowercase-id>`. |
| `cache_write_5m_tokens`, `cache_write_1h_tokens` | Cache-write split, a subset of `cache_write_tokens`. Priced at different rates. `NULL` means the client did not split it — pricing then uses `cache_write_tokens` at the 5-minute rate. Added in schema v2; filled when a row is re-read from a log that reports the split, never guessed for rows whose logs are gone. |
| `project_key` | Working directory the client reported. A path, not a label; `NULL` when the log never states one — adapters must not guess it from a file path. |
| `revision`, `active`, `superseded_by` | Growth updates the row in place; nothing is deleted. Only `active = 1` rows are counted. A row goes inactive when a newer parser revision no longer produces it from the same file, or when a record with a new identity names its key in `replaces` (then `superseded_by` points at the new row). |
| `source_file`, `parser_rev` | Log file and adapter revision (`PARSER_REV` in `src/core/adapters/index.js`) that last produced the row. Added in schema v4; `NULL` for rows not re-read since, which are never deactivated and count as revision 1. Bump an adapter's revision whenever its values, identities or times change. |
| `price_version`, `cost_micros`, `price_source` | Money is integer micro-USD (USD × 1e6). |

Invariants:

- `gross_tokens = input + output + cache_read + cache_write`, with no overlap between the four. In SQL, sum each column and add the results, or wrap every column in `coalesce`; `sum(a + b + c + d)` returns NULL as soon as one row has a NULL field, which reads like "no data" instead of "one column is unknown". The cache-write split columns are a breakdown of `cache_write_tokens`, not a fifth kind: they must sum to it and never enter `gross_tokens` on their own.
- Adapters subtract cached prefixes when the client reports an inclusive total, so the query layer never adjusts token counts.
- One event appears once. When the same event record turns up in several files of one source (a branched or resumed session copies earlier messages), ingestion writes it from the file that starts earliest, so it stays with the original session; the other copies are counted as `cross_file_copies` and do not count as vanished from their files. Cumulative snapshots are not merged this way.
- Re-reading a record does not create a second row. A growing `event` record updates its row; a `cumulative` record overwrites; a `cumulative` decrease is accepted only when the adapter revision changed, otherwise it is reported as an anomaly and the previous value is kept. A record that disappears from a file under the same revision is reported as `vanished` and keeps counting: a client pruning its log does not undo the usage.
- Grouping sums equal the overall totals for both tokens and money. Time buckets plus the `unallocated` bucket equal the totals as well.

## Boundary

- `src/core/http/gate.js` rejects any `Host` outside loopback, requires a bearer token for `/api/*`, and requires a same-origin or absent `Origin` on writes. No CORS headers are ever sent.
- `src/core/http/token.js` keeps the API token in `<data-dir>/api-token`. `index.html` receives it as `<meta name="lens-api-token">`.
- `src/core/http/port.js` binds 127.0.0.1 and advances to the next port only on `EADDRINUSE`; it never probes a port, releases it, then listens.
- `src/core/sync-lock.js` gives the ingestion kernel a cross-process lock on `sync-lock.db`; a second caller gets a busy error (or 409 over HTTP).
- Any path under `/api/` or `/functions/` that the router does not handle answers 404 JSON; the SPA fallback never serves an API path. The legacy `/functions/token-lens-*` shim and `/api/local-auth` are gone.

## Adapters

One file per client under `src/core/adapters/`. Each yields `record_key`, `source`, `session_id`, `project_key`, `model`, `observed_at`, `kind`, and the four token fields; adapters with a verified log field also yield `provider`. Missing provider is stored as NULL. Field locations and per-client semantics are recorded in `specs/log-schemas.yaml` and `specs/adapters.md`.

`_zstd.js` decodes concatenated zstd frames. `node:zlib` decodes only the first frame of a joined stream, so adapters that read `.zst` files must go through it.

## Dashboard

`dashboard/src/App.jsx` owns local routes. The dashboard does not sign in and does not upload usage.

- `src/styles/tokens.css` is the only place colours, radii and shadows are defined; `tailwind.config.cjs` maps those variables to class names. Light and dark values live side by side there.
- `src/ui/lens/` holds the primitives (button, card, badge, segmented control, stat tile, chart, empty state). `src/lib/chart.ts` keeps chart geometry as pure functions so it can be tested without a DOM.
- Page copy is written in Chinese inline; only shell strings go through `copy()`, and `src/content/` carries just the keys that surviving code calls.
- `/dashboard` has two views: the overview and `?view=detail` (filters `tool`, `model`, `project`, `bucket`, split `dim`). `src/lib/detail-query.js` builds and reads those URLs for the home page, the sidebar and the detail view. `/usage` redirects there.
- Charts never use brand colours. `src/lib/tool-colors.ts` gives each tool a `--lens-cat-*` slot in the order it first appeared (`first_observed_at` from `/sources`), and stacks follow that order. Brand colours stay on the logo tiles.
- `src/lib/brand-mark.js` is the only definition of the Token Lens mark (a lens with bars inside). The sidebar draws it with CSS variables; `node scripts/icons/build-icons.mjs` regenerates every file in `public/` that shows it (favicon, PNGs, `favicon.ico`). After changing the mark, rerun it and bump the `?v=` on the icon links in `index.html`.


