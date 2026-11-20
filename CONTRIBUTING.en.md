# Contributing

This is a shorter English version of [CONTRIBUTING.md](CONTRIBUTING.md). Most specifications and code comments in this repository are in Chinese; issues and pull requests in English are welcome.

## Getting started

The desktop app lives in `app/`: a Flutter interface and a Rust core, connected through flutter_rust_bridge. The older Node/React tool (`src/`, `dashboard/`, `desktop/`, `bin/`) is frozen: new features and new tools go into the desktop app only.

1. **Install** Flutter stable 3.47.9 (Dart 3.13.7), Rust 1.98.0 and Python 3.
   - Windows also needs Visual Studio's "Desktop development with C++" and permission to create symbolic links (turn on Developer Mode).
   - macOS needs Xcode.
   - flutter_rust_bridge_codegen 2.13.0 and cargo-expand are needed only when you change the Rust interface that Flutter calls.
2. **Fetch dependencies**:

   ```sh
   cd app
   flutter pub get --enforce-lockfile
   cd ..
   cargo fetch --manifest-path app/rust/Cargo.toml --locked --target x86_64-pc-windows-msvc --target aarch64-apple-darwin
   ```

   The `cargo fetch` step is needed only for the full check, which verifies third-party licenses for both release targets.
3. **Run with demo data**: `python scripts/desktop-dev.py demo` (`python3` on macOS). It generates a fixed set of synthetic logs for a few tools over about 90 days, syncs them through the real ingestion path, and opens the app on that data. The temporary folder is removed on exit; add `--keep` to keep it.
4. **Check before you push**: `python scripts/desktop-dev.py check` runs the same checks as desktop CI. Add `--only rust` or `--only flutter` for a faster partial run.

Always run and test through `scripts/desktop-dev.py`. A debug build refuses to start unless both `TOKEN_LENS_PREVIEW_DATA_DIR` (ledger and settings) and `TOKEN_LENS_PREVIEW_HOME` (where tool logs are found) are set. The script points both at temporary folders, so the app never reads your real logs or ledger during development. Never point them at your real home or app data folder.

More detail: [app/README.md](app/README.md). To support a new AI coding tool, read [docs/development/adding-a-source.md](docs/development/adding-a-source.md) (in Chinese).

## Issues

- Use the issue forms. One issue per problem; search closed issues first.
- For bugs, include the app version (Pricing & settings → About this installation of Token Lens), OS and architecture, how you installed it, and which tools are involved. You can attach the file from **Export diagnostics**; read it first and remove project or file names you don't want to share.
- Never paste prompts, code, credentials, tokens, or absolute paths that contain your user name.
- Report security issues privately, as described in [SECURITY.md](SECURITY.md).

## Pull requests

- Open an issue first for large changes. One pull request does one thing.
- Fill in [the pull request template](.github/pull_request_template.md).
- Desktop changes: `python scripts/desktop-dev.py check` must pass. For interface changes, attach before and after screenshots taken with the demo data, not your own.
- The frozen Node/React tool accepts only fixes that affect its use as a rollback; run `npm run ci:local` (Node >= 24.21.0) for those.
- Dependency upgrades go in their own pull request with the updated lockfiles and regenerated third-party notices.

## Using AI

AI-assisted contributions are fine if you disclose the tool, model and what it was used for. You must understand every changed line and run the checks yourself. Undisclosed or unverified automated pull requests are closed.

## Not accepted

Cloud accounts, uploading data, telemetry, leaderboards; installing hooks or plugins into other tools' folders or changing their configuration; skills management, achievements, pets, share pages; changes to the copyright notice in LICENSE.

## License

By contributing you agree that your changes are released under the MIT License.
