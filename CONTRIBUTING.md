# 贡献指南

English contributions are welcome. A shorter English version is in [CONTRIBUTING.en.md](CONTRIBUTING.en.md).

## 开发快速开始

Token Lens 的桌面应用在 `app/`：Flutter 界面加 Rust 核心，两者通过 flutter_rust_bridge 连接。仓库里另有旧版 Node/React 工具（`src/`、`dashboard/`、`desktop/`、`bin/`），它已经冻结，新功能和新来源只写进桌面版。

### 1. 准备环境

- Flutter stable 3.47.9（Dart 3.13.7）、Rust 1.98.0、Python 3。
- Windows 需要 Visual Studio 的「使用 C++ 的桌面开发」，以及符号链接权限（打开 Windows 开发者模式即可）。macOS 需要 Xcode。
- 改 Rust 公共接口时才需要 flutter_rust_bridge_codegen 2.13.0 和 cargo-expand。

详细的环境变量写法见 [app/README.md 的「环境」](app/README.md#环境)。

### 2. 取依赖

```sh
cd app
flutter pub get --enforce-lockfile
cd ..
cargo fetch --manifest-path app/rust/Cargo.toml --locked --target x86_64-pc-windows-msvc --target aarch64-apple-darwin
```

第二条只在跑完整检查时需要：它会核对 Windows 和 macOS 两个发行目标的第三方许可。

### 3. 用演示数据看效果

```sh
python scripts/desktop-dev.py demo
```

它会在临时目录里生成一套固定的合成日志（几个工具、约 90 天），走一遍真实的同步，再用这份数据启动应用，退出后删除临时目录。加 `--keep` 保留目录。macOS 用 `python3`。

`python scripts/desktop-dev.py run` 只放一条记录，启动更快，适合调试启动和空数据的界面。

### 4. 为什么一定要隔离

开发时应用和测试都不应读到你自己的真实日志和账本。调试构建必须同时设置两个目录才能启动：
- `TOKEN_LENS_PREVIEW_DATA_DIR`：账本和设置放在哪里；
- `TOKEN_LENS_PREVIEW_HOME`：从哪里找各工具的日志。设置后，所有工具的日志位置都从它推出，客户端自己的覆盖变量也不再生效。

`scripts/desktop-dev.py` 会为每次运行建好临时目录并设置这两个变量，所以请始终通过它运行和检查。不要把这两个变量指向你真实的用户目录或应用数据目录。

### 5. 改完以后检查

```sh
python scripts/desktop-dev.py check
```

它和桌面 CI 用的是同一个入口：Rust 和 Dart 的格式、静态分析、全部测试、演示数据同步、第三方声明和锁文件核对。只想快速跑一半时，加 `--only rust` 或 `--only flutter`。

### 代码在哪里

| 位置 | 内容 |
| --- | --- |
| `app/lib/stats/` | 统计界面：总览、明细、会话、工具、价格与设置、首次引导 |
| `app/lib/l10n/` | 界面文字。中文和英文各一份，少写一份通不过分析 |
| `app/rust/src/stats/adapters/` | 每个工具一个解析器 |
| `app/rust/src/stats/discovery.rs` | 去哪里找各工具的日志 |
| `app/rust/src/stats/ledger/`、`service/` | 账本读写和统计查询 |
| `app/rust/src/cli.rs` | 只读 JSON 命令行 `token-lens-cli` |
| `specs/` | 契约：日志字段、适配器口径、统计规则、命令行格式、价格 |

### 常见改动从哪里开始

- **支持一个新工具**：读 [新增一个工具来源](docs/adding-a-source.md)。
- **改界面文字**：在 `app/lib/l10n/app_strings.dart` 声明，`strings_zh.dart` 和 `strings_en.dart` 各写一份。
- **改了 Rust 对 Flutter 公开的接口**：在 `app/` 运行 `flutter_rust_bridge_codegen generate`，生成的文件一起提交。
- **改模型价格**：见 [specs/pricing.md](specs/pricing.md) 第 9 节，单独开 PR。

## 提交 Issue

- 走 issue 表单提交：问题报告与功能建议两种表单，按表单字段逐项填写。
- 一个 issue 只说一件事；提交前先搜索已关闭 issue，避免重复。
- 问题报告请附环境信息：
  - 桌面版：应用版本（「价格与设置 → 关于这台电脑上的 Token Lens」）、操作系统和架构、安装方式（发布包 zip 或源码构建）、涉及的客户端。需要时可以附「导出诊断日志」生成的文件，发之前自己看一遍，删掉不想公开的项目名和文件名。
  - 旧版 Node/React 工具：Node 版本（要求 >= 24.21.0）、涉及的客户端，以及脱敏后的 `node bin/lens.js summary` 输出。
- 不要粘贴提示词、代码、凭据、真实令牌，也不要贴含用户名的绝对路径。
- 安全问题不要开公开 issue，请按 [安全政策 · 报告漏洞](SECURITY.md#报告漏洞) 私下报告。

## 提交 PR

- 大改动先开 issue 达成一致再动手。
- 一 PR 只做一件事；混了多件事的 PR 会被要求拆分。
- 按 [.github/pull_request_template.md](.github/pull_request_template.md) 填写。
- 改动了桌面应用（`app/`）：提交前跑 `python scripts/desktop-dev.py check`，见上面的「开发快速开始」。改了界面的话附前后截图，用 `python scripts/desktop-dev.py demo` 的演示数据截，不要用你自己的真实数据。
- 旧版（`src/core/`、`dashboard/`、`desktop/`、`bin/`）已冻结，只接受影响回退使用的缺陷修复，不接受新功能和新来源。修复时本地环境用 Node >= 24.21.0，依赖用 `npm ci` 和 `npm ci --prefix dashboard` 安装；提交前跑 `npm run ci:local`（核心测试 + 仪表盘测试 + 构建 + 类型检查，在临时用户目录与显式数据目录下执行，结束后清理）。测试约定见 [CLAUDE.md](CLAUDE.md)。
- 自动检查：
  - `desktop.yml`：改动 `app/`、`specs/`、`test/fixtures/`、桌面相关脚本、第三方声明或发布流程时，在 Windows 和 macOS 上构建、测试并冒烟。
  - `pr-checks.yml`：旧版的 `npm run ci:local` 和旧版桌面构建。只改了 Markdown、issue 模板，或者只改了桌面版的文件（`app/` 和桌面专用的脚本、工作流）时跳过。

## 依赖升级

- 桌面应用的 Flutter 和 Rust 依赖分别由 `app/pubspec.lock`、`app/rust/Cargo.lock` 锁定；升级单独开 PR，一并提交锁文件，并重新生成第三方声明（`scripts/generate-desktop-notices.dart`，用 `--check` 确认）。
- 旧版核心零依赖是硬约束：根 package.json 的 `dependencies` 必须保持 `{}`，功能优先用 Node 内置模块（`node:sqlite`、`node:http`、`node:crypto`、`node:zlib` 等）实现。
- 仪表盘依赖升级单独开 PR，不与其他改动混在一起；`dashboard/package-lock.json` 一并提交，附 `npm ls --prefix dashboard` 的解析结果与 `npm run ci:local` 的运行结果。
- 不得引入会触发 npx 下载的行为：本地缺少运行时也不得自动下载依赖。

## 使用 AI

- 可以用 AI 辅助开发，但必须披露：工具名、模型版本、用途（发现问题 / 写代码 / 写测试 / 写说明）。
- 作者必须逐行理解全部改动并亲自验证，至少跑上面对应的检查。
- 引用 AI 发现的问题时，须给出可复现步骤或具体代码位置。
- 未披露或未经作者验证的自动化 PR 直接关闭。

## 不接受的改动

以下改动一律不接受：

- 云端账户、数据上传、遥测、排行榜；
- 给其他工具的目录安装钩子、插件或修改其配置；
- Skills 管理、成就、宠物、分享页；
- 修改 LICENSE 中的版权声明。

## 许可

- 提交即表示按 MIT 许可贡献你的改动。
