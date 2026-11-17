# Token Lens 桌面应用

Flutter + Rust 重写已完成 D2.6、D3.5 与 D4：20 个新闻与工具更新来源（按天分组、本机已读与收藏、当前热点、条目类型筛选、来源内热度排序、启停、本地缓存、每 30 分钟自动刷新与手动刷新、取消和错误反馈），以及完整的统计界面（用量总览、明细、会话、工具来源、价格与设置、首次引导；27 个来源的采集和查询都已迁移）。D4 已在开发机上把日常使用切换到新版；仓库原有的 Node/React 版本仍可运行，用于回退，还没有安装包。技术决定见 [desktop.md](../specs/desktop.md)，数据与联网边界见 [news.md](../specs/news.md)、[stats.md](../specs/stats.md)。

启动打开用量总览，侧栏按「用量 / 资讯 / 设置」分组，「AI 热点」位于资讯组。统计在窗口打开时采集一次，每 5 分钟采集一次，也可点击「同步」；新闻的联网时机见下方「运行与回退」。账本是应用数据目录下的 `ledger.db`，不读取旧版数据目录变量。

开发和冒烟须同时隔离账本与日志根目录：`TOKEN_LENS_PREVIEW_DATA_DIR` 指定独立的测试数据目录，`TOKEN_LENS_PREVIEW_HOME` 指定合成日志根目录（其下为 `.claude/projects/**/*.jsonl`、`.codex/sessions/**/rollout-*.jsonl[.zst]`）。未覆盖日志根目录时，发行运行读取系统用户目录的客户端日志；开发检查始终设置合成根。

在仓库根目录、隔离环境下运行 `node scripts/parity/generate.mjs` 重建 `app/rust/tests/golden/*.jsonl`。生成器只 import 旧版生产入口；固定 Date 为 `2026-01-15T12:00:00.000Z`，主时区为 `Asia/Shanghai`，另含 UTC 向量。只有 SQLite 默认时间和采集耗时使用明确的 volatile 占位。`cargo test --manifest-path app/rust/Cargo.toml --locked` 读取相同静态夹具，验证适配器、身份字节、写入、迁移、计价与查询。

## 环境

- Flutter stable 3.47.9（Dart 3.13.7）。
- Rust 1.98.0；Windows 构建需要 Visual Studio Desktop development with C++ 和符号链接权限（通常通过 Windows Developer Mode 提供），macOS 构建需要 Xcode。
- flutter_rust_bridge 与 codegen 2.13.0；代码生成另需 cargo-expand。
- Flutter/Rust 依赖分别由 `pubspec.lock`、`rust/Cargo.lock` 锁定。生产包不要求用户安装 Flutter、Rust 或 Node。

已批准的 Windows 开发环境：SDK `<flutter-sdk>`（Flutter SDK 的绝对目录），Pub 缓存 `<pub-cache>`（Pub 依赖缓存的绝对目录），代码生成工具 `<frb-tools>`（FRB 代码生成工具所在的 bin 目录，使用绝对路径）。PATH 只在开发进程内设置，不修改系统 PATH。工具和依赖缓存按正常安装保留。

```powershell
$env:PATH = "<flutter-sdk>\bin;<frb-tools>;$env:PATH"
$env:PUB_CACHE = '<pub-cache>'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
cd app
flutter pub get --enforce-lockfile
```

## 开发与检查

调试运行必须提供独立的绝对目录；未设置时显示说明并停止初始化。不要把目录指向真实 home、旧账本或已安装应用的数据目录。`<独立的测试数据目录>` 表示满足这些条件的测试数据绝对目录。

```powershell
$env:TOKEN_LENS_PREVIEW_DATA_DIR = '<独立的测试数据目录>'
flutter run -d windows
```

修改 Rust 公共接口后，在 `app/` 重新生成桥接，再检查：

```sh
flutter_rust_bridge_codegen generate
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo test --manifest-path rust/Cargo.toml --locked
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
flutter analyze
flutter test
flutter build windows --release
```

macOS 使用 `flutter run -d macos` 和 `flutter build macos --release`；Windows 不能验证 macOS 构建。Flutter native-assets hook 编译并打包 Rust 动态库；测试与发行不需要额外启动 Rust 服务。测试使用合成缓存、临时目录与 loopback HTTP server，不自动请求公共来源。

## 运行与回退

Windows release 的程序名为 `token-lens.exe`，产品名和窗口标题为 `Token Lens`；必须保留构建输出中的 exe、DLL 与 `data/`，不能只复制 exe。尚未制作替换旧版的自解压安装包或 dmg。macOS 的应用名为 `Token Lens.app`，bundle id 为 `io.github.rumoii.token-lens`。

启动先读新闻缓存；所有已启用来源都没有 30 分钟内的成功刷新时，立即刷新一次，之后程序开着时每 30 分钟自动刷新；本地没有任何条目且全部来源失败时，2 分钟、10 分钟后各提前重试一次。也可以手动刷新全部已启用来源或单一来源；单来源失败保留其旧内容，取消保留已经完成的提交。分类、范围、搜索和筛选只处理本地数据；已读和收藏只存在本机；原文在系统浏览器打开。关闭退出，不留常驻进程。一个缓存目录只允许一个写入者。

应用默认使用系统应用支持目录下的 `data`（Windows 为 `%APPDATA%\Token Lens\Token Lens\data`），可以用 `TOKEN_LENS_PREVIEW_DATA_DIR` 覆盖为绝对路径。`TOKEN_LENS_PREVIEW_HOME` 仍用于覆盖日志根目录。它忽略旧版 `TOKEN_LENS_DATA_DIR` 与 `DB_PATH`，不自动读取或迁移旧新闻目录及 `~/.token-lens`。

接手旧版账本：先关闭新旧两版，备份 `~/.token-lens`，再把其中的 `ledger.db` 以及存在的 `ledger.db-wal`、`ledger.db-shm` 一起复制到新版数据目录，然后启动新版。三个文件要同时复制，WAL 里可能有尚未合并进 `ledger.db` 的记录。桌面版会在自己的数据目录用 `VACUUM INTO` 保存一致的 v5 备份，再升级到 v6（增加独立 usage_timings，不改用量表和价格）。不要在程序运行时直接复制主文件充当一致备份。

回退到 Node/React 版：关闭桌面版，继续使用旧版。桌面版从不打开 `~/.token-lens`，那里的 v5 账本只由旧版自己写入，不受桌面 v6 迁移影响。

回退到 schema v5 的旧桌面程序：旧程序拒绝打开 v6，不能只换 exe 后继续用 v6 数据目录。

1. 关闭所有桌面实例，保留 v6 数据目录及其 WAL/SHM，不覆盖它们。
2. 在该目录找到升级前生成的 `ledger-v5-YYYY-MM-DD-<毫秒时间>-<序号>.db`，核实它能以 SQLite 打开、user_version 为 5；恢复点是备份时刻，之后采集的记录不在该备份里。
3. 新建一个独立的空恢复目录，把备份复制到其中并命名为 `ledger.db`。不要带入 v6 的 WAL/SHM；备份是 VACUUM INTO 生成的完整独立数据库。
4. 在启动旧桌面程序的进程里把 `TOKEN_LENS_PREVIEW_DATA_DIR` 设置为恢复目录的绝对路径，再启动完整的旧版构建目录。恢复不需要改动 `~/.token-lens`；保留原 v6 目录，以便恢复新版时继续使用。

Windows 单实例互斥量为 `Local\TokenLens.Desktop`，重复启动仅激活类名为 `FLUTTER_RUNNER_WIN32_WINDOW`、标题为 `Token Lens` 的窗口。

## 发布

对外版本是 `pubspec.yaml` 里 `version` 的 `+` 前部分，按语义化版本编号；`+` 后的构建号不进入标签和包名。1.0 之前，加了新功能升第二位（0.1.0 → 0.2.0），只修问题升第三位（0.2.0 → 0.2.1）。首个公开版本是 0.1.0。

1. 修改 `pubspec.yaml` 的 `version`，提交到 main。
2. 在这个提交上打标签 `v<版本>`（例如 `v0.1.0`）并推送。
3. `.github/workflows/release.yml` 先核对标签与 `pubspec.yaml` 的版本一致，不一致就失败；一致时在 GitHub 托管的 Windows、macOS runner 上构建，打成 `token-lens-<版本>-windows-x64.zip`（Release 目录的全部内容，含 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`THIRD_PARTY_LICENSES.txt`）和 `token-lens-<版本>-macos.zip`（顶层为 `Token Lens.app` 和这三个文本文件），各附一个 `.sha256` 校验文件，然后建草稿 Release 并上传这四个文件。同一标签的 Release 已存在时失败，不覆盖。
4. 检查草稿里的文件和说明，再在 GitHub 上手动发布。
