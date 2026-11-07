# Token Lens 桌面预览

Flutter + Rust 重写的 D3.1：19 个新闻与工具更新来源、条目类型筛选、来源内热度排序、按来源手动刷新、启停、本地缓存、取消和错误反馈，以及 Claude/Codex 统计总览。其余统计功能继续使用仓库原有版本。技术决定见 [desktop.md](../specs/desktop.md)，数据与联网边界见 [news.md](../specs/news.md)、[stats.md](../specs/stats.md)。

统计总览可在「新闻 / 统计」间切换。统计在窗口打开时采集一次，每 5 分钟采集一次，也可点击「同步」；新闻仍只在点击刷新后联网。账本是预览目录下的 `ledger.db`，不读取旧版数据目录变量。

开发和冒烟须同时隔离账本与日志根目录：`TOKEN_LENS_PREVIEW_DATA_DIR` 指定独立的预览目录，`TOKEN_LENS_PREVIEW_HOME` 指定合成日志根目录（其下为 `.claude/projects/**/*.jsonl`、`.codex/sessions/**/rollout-*.jsonl[.zst]`）。未覆盖日志根目录时，发行运行读取系统用户目录的客户端日志；开发检查始终设置合成根。

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

调试运行必须提供独立的绝对目录；未设置时显示说明并停止初始化。不要把目录指向真实 home、旧账本或已安装应用的数据目录。`<独立的预览目录>` 表示满足这些条件的预览数据绝对目录。

```powershell
$env:TOKEN_LENS_PREVIEW_DATA_DIR = '<独立的预览目录>'
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

Windows release 必须保留构建输出中的 exe、DLL 与 `data/`，不能只复制 exe。此阶段提供开发预览，尚未制作替换旧版的自解压安装包或 dmg。

启动不联网。点击刷新才请求全部已启用来源或选定单一来源；单来源失败保留其旧内容，取消保留已经完成的提交。分类、搜索、来源筛选和列表／卡片切换只处理本地数据；原文在系统浏览器打开。关闭退出，不留常驻进程。一个缓存目录只允许一个写入者。

预览默认使用系统应用支持目录下的 `news-preview`，可以用 `TOKEN_LENS_PREVIEW_DATA_DIR` 覆盖为绝对路径。它忽略旧版 `TOKEN_LENS_DATA_DIR` 与 `DB_PATH`，不读取或修改旧账本。回退只需退出预览并继续使用原版。
