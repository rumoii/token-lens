# 贡献指南

English contributions are welcome.

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
- 改动了桌面应用（`app/`）：环境和检查命令见 [app/README.md 的「开发与检查」](app/README.md#开发与检查)，至少跑 `cargo fmt --check`、`cargo clippy`、`cargo test`、`dart format`、`flutter analyze`、`flutter test`。开发运行必须同时设置 `TOKEN_LENS_PREVIEW_DATA_DIR` 和 `TOKEN_LENS_PREVIEW_HOME`，指向独立的临时目录，不要让开发版读到你真实的日志或账本。改了界面的话附前后截图。
- 改动了旧版（`src/core/`、`dashboard/`、`desktop/`、`bin/`）：本地环境 Node >= 24.21.0，依赖用 `npm ci` 和 `npm ci --prefix dashboard` 安装；提交前跑 `npm run ci:local`（核心测试 + 仪表盘测试 + 构建 + 类型检查，在临时用户目录与显式数据目录下执行，结束后清理）；改动了 `dashboard/` 的话，在本地看板手动验证页面行为。测试约定见 [CLAUDE.md](CLAUDE.md)。
- 自动检查：
  - `desktop.yml`：改动 `app/`、`specs/`、桌面相关脚本、第三方声明或发布流程时，在 Windows 和 macOS 上构建、测试并冒烟。
  - `pr-checks.yml`：旧版的 `npm run ci:local`；只改了 Markdown 或 issue 模板时跳过测试。

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
