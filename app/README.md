# Token Lens 桌面应用

Token Lens 的桌面应用：Flutter 界面加 Rust 核心。它包括完整的统计界面（用量总览、明细、会话、工具来源、价格与设置、首次引导；28 个来源的采集和查询）、AI 热点（20 个新闻与工具更新来源，按天分组、本机已读与收藏、当前热点、条目类型筛选、来源内热度排序、启停、本地缓存、每 30 分钟自动刷新与手动刷新）和检查更新。仓库里的旧版 Node/React 工具仍可运行，可以作为回退。技术决定见 [desktop.md](../specs/desktop.md)，数据与联网边界见 [news.md](../specs/news.md)、[stats.md](../specs/stats.md)、[update.md](../specs/update.md)。

启动打开用量总览，侧栏按「用量 / 资讯 / 设置」分组，「AI 热点」位于资讯组。第一次打开时首次引导只列出找到的工具，点「开始统计」后才读取日志；之后统计在窗口打开时采集一次，每 5 分钟采集一次，也可点「同步用量」。新闻的联网时机见下方「运行与回退」。账本是应用数据目录下的 `ledger.db`，不读取旧版数据目录变量。

开发和冒烟须同时隔离账本与日志根目录：`TOKEN_LENS_PREVIEW_DATA_DIR` 指定独立的测试数据目录，`TOKEN_LENS_PREVIEW_HOME` 指定合成日志根目录。设了日志根目录，所有客户端的日志位置都从它推出（如 `.claude/projects`、Windows 的 `AppData/Roaming`、`.local/share`），继承来的 `APPDATA`、`LOCALAPPDATA`、`XDG_DATA_HOME` 和客户端自己的覆盖变量（如 `OPENCODE_DB`、`GEMINI_HOME`）一律不生效，开发运行和测试因此读不到真实日志；各变量对应的位置以 `app/rust/src/stats/discovery.rs` 的 `Environment::preview` 为准。没设日志根目录时（正式发行的正常运行），读取系统用户目录和这些变量指向的位置。调试构建缺任一预览目录都拒绝启动；`scripts/desktop-dev.py` 会自动建好这两个目录。

在仓库根目录、隔离环境下运行 `node scripts/parity/generate.mjs` 重建 `app/rust/tests/golden/*.jsonl`。生成器只 import 旧版生产入口；固定 Date 为 `2026-01-15T12:00:00.000Z`，主时区为 `Asia/Shanghai`，另含 UTC 向量。只有 SQLite 默认时间和采集耗时使用明确的 volatile 占位。`cargo test --manifest-path app/rust/Cargo.toml --locked` 读取相同静态夹具，验证适配器、身份字节、写入、迁移、计价与查询。

## 环境

- Flutter stable 3.47.9（Dart 3.13.7）。
- Rust 1.98.0；Windows 构建需要 Visual Studio Desktop development with C++ 和符号链接权限（通常通过 Windows Developer Mode 提供），macOS 构建需要 Xcode。
- flutter_rust_bridge 与 codegen 2.13.0；代码生成另需 cargo-expand。
- Flutter/Rust 依赖分别由 `pubspec.lock`、`rust/Cargo.lock` 锁定。生产包不要求用户安装 Flutter、Rust 或 Node。

Windows 开发环境示例：把下面的占位换成你自己的绝对路径，SDK `<flutter-sdk>`（Flutter SDK 目录），Pub 缓存 `<pub-cache>`（Pub 依赖缓存目录），代码生成工具 `<frb-tools>`（FRB 代码生成工具所在的 bin 目录）。PATH 只在开发进程内设置，不修改系统 PATH。

```powershell
$env:PATH = "<flutter-sdk>\bin;<frb-tools>;$env:PATH"
$env:PUB_CACHE = '<pub-cache>'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
cd app
flutter pub get --enforce-lockfile
```

## 开发与检查

在 `app/` 用 `flutter pub get --enforce-lockfile` 准备依赖，再从仓库根目录运行。入口会为账本、日志和测试建立临时目录。调试运行用合成日志，结束后清理目录，可加 `--keep` 保留。

```sh
python scripts/desktop-dev.py run
python scripts/desktop-dev.py check
```

macOS 可用 `python3`。调试运行需同时设置预览数据目录与预览日志根，发现逻辑从预览日志根解析各客户端的默认位置。检查与桌面 CI 共用入口，可加 `--only rust` 或 `--only flutter`。完整检查需要两个发行目标的 Cargo 缓存。

```sh
cargo fetch --manifest-path app/rust/Cargo.toml --locked --target x86_64-pc-windows-msvc --target aarch64-apple-darwin
```

修改 Rust 公共接口后，在 `app/` 运行 `flutter_rust_bridge_codegen generate`，再执行完整检查。构建发行版用 `flutter build windows --release --no-pub` 或 `flutter build macos --release --no-pub`。Flutter native-assets hook 编译并打包 Rust 动态库；测试与发行不需要额外启动 Rust 服务。

## 运行与回退

Windows release 的程序名为 `token-lens.exe`，产品名和窗口标题为 `Token Lens`；必须保留构建输出中的 exe、DLL 与 `data/`，不能只复制 exe。尚未制作替换旧版的自解压安装包或 dmg。macOS 的应用名为 `Token Lens.app`，bundle id 为 `io.github.rumoii.token-lens`。

启动先读新闻缓存；所有已启用来源都没有 30 分钟内的成功刷新时，立即刷新一次，之后程序开着时每 30 分钟自动刷新；本地没有任何条目且全部来源失败时，2 分钟、10 分钟后各提前重试一次。也可以手动刷新全部已启用来源或单一来源；单来源失败保留其旧内容，取消保留已经完成的提交。分类、范围、搜索和筛选只处理本地数据；已读和收藏只存在本机；原文在系统浏览器打开。关闭退出，不留常驻进程。一个缓存目录只允许一个写入者。

应用默认使用系统应用支持目录下的 `data`（Windows 为 `%APPDATA%\Token Lens\Token Lens\data`），可以用 `TOKEN_LENS_PREVIEW_DATA_DIR` 覆盖为绝对路径。`TOKEN_LENS_PREVIEW_HOME` 仍用于覆盖日志根目录。它忽略旧版 `TOKEN_LENS_DATA_DIR` 与 `DB_PATH`，不自动读取或迁移旧新闻目录及 `~/.token-lens`。

接手旧版账本：先关闭新旧两版，备份 `~/.token-lens`，再把其中的 `ledger.db` 以及存在的 `ledger.db-wal`、`ledger.db-shm` 一起复制到新版数据目录，然后启动新版。三个文件要同时复制，WAL 里可能有尚未合并进 `ledger.db` 的记录。桌面版每次升级账本结构前，都会在自己的数据目录用 `VACUUM INTO` 保存一份升级前版本的一致备份：升 v6（增加独立 usage_timings，不改用量表和价格）前存 v5 备份 `ledger-v5-…db`，升 v7（增加文件缓存表，不改用量、计时和价格）前存 v6 备份 `ledger-v6-…db`。不要在程序运行时直接复制主文件充当一致备份。

回退到 Node/React 版：关闭桌面版，继续使用旧版。桌面版从不打开 `~/.token-lens`，那里的 v5 账本只由旧版自己写入，不受桌面迁移影响。

回退到更早 schema 的旧桌面程序：旧程序拒绝打开更高版本的账本，不能只换 exe 后继续用新的数据目录。以回到 v6 程序为例（回到 v5 程序时把 v6 换成 v5、v7 换成 v6）：

1. 关闭所有桌面实例，保留 v7 数据目录及其 WAL/SHM，不覆盖它们。
2. 在该目录找到升级前生成的 `ledger-v6-YYYY-MM-DD-<毫秒时间>-<序号>.db`，核实它能以 SQLite 打开、user_version 为 6；恢复点是备份时刻，之后采集的记录不在该备份里。
3. 新建一个独立的空恢复目录，把备份复制到其中并命名为 `ledger.db`。不要带入 v7 的 WAL/SHM；备份是 VACUUM INTO 生成的完整独立数据库。
4. 在启动旧桌面程序的进程里把 `TOKEN_LENS_PREVIEW_DATA_DIR` 设置为恢复目录的绝对路径，再启动完整的旧版构建目录。恢复不需要改动 `~/.token-lens`；保留原 v7 目录，以便恢复新版时继续使用。

“重新读取全部日志”（来源页）只是不看文件缓存把日志重读一遍，不清空账本，也不是回退手段。

Windows 单实例互斥量为 `Local\TokenLens.Desktop`，重复启动仅激活类名为 `FLUTTER_RUNNER_WIN32_WINDOW`、标题为 `Token Lens` 的窗口。

## 发布

对外版本是 `pubspec.yaml` 里 `version` 的 `+` 前部分，按语义化版本编号；`+` 后的构建号不进入标签和包名。1.0 之前，加了新功能升第二位（0.1.0 → 0.2.0），只修问题升第三位（0.2.0 → 0.2.1）。首个公开版本是 0.1.0。

1. 修改 `pubspec.yaml` 的 `version` 和 `rust/Cargo.toml` 的 `version`（两处必须一致，`rust/Cargo.lock` 随之更新），提交到 main。
2. 在这个提交上打标签 `v<版本>`（例如 `v0.1.0`）并推送。
3. `.github/workflows/release.yml` 先核对标签与 `pubspec.yaml` 的版本一致，不一致就失败；一致时在该标签的提交上跑完整桌面检查（调用 `desktop.yml`，Windows、macOS 都要通过），再在 GitHub 托管的 Windows、macOS runner 上构建，打成 `token-lens-<版本>-windows-x64.zip`（Release 目录的全部内容，含 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`THIRD_PARTY_LICENSES.txt`）和 `token-lens-<版本>-macos.zip`（顶层为 `Token Lens.app` 和这三个文本文件），每个 ZIP 先解到临时目录，用 `scripts/verify-desktop-zip.py` 核对程序、资源和三个许可文件都在，并对解包出来的程序跑一次合成数据冒烟；通过后各附一个 `.sha256` 校验文件，然后建草稿 Release 并上传这四个文件。同一标签的 Release 已存在时失败，不覆盖。
4. 检查草稿里的文件和说明，再在 GitHub 上手动发布。
