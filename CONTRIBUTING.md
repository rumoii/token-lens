# 贡献指南

English contributions are welcome.

## 提交 Issue

- 走 issue 表单提交：问题报告与功能建议两种表单，按表单字段逐项填写。
- 一个 issue 只说一件事；提交前先搜索已关闭 issue，避免重复。
- 问题报告请附环境信息：操作系统、Node 版本（要求 >= 24.21.0）、涉及的客户端，以及脱敏后的 `npm run summary` 输出。
- 不要粘贴提示词、代码、凭据、真实令牌，也不要贴含用户名的绝对路径。
- 安全问题不要开公开 issue，请按 [安全政策 · 报告漏洞](SECURITY.md#报告漏洞) 私下报告。

## 提交 PR

- 本地环境：Node >= 24.21.0；依赖用 `npm ci`（核心）与 `npm ci --prefix dashboard`（仪表盘）安装。
- 大改动先开 issue 达成一致再动手。
- 一 PR 只做一件事；混了多件事的 PR 会被要求拆分。
- 按 [.github/pull_request_template.md](.github/pull_request_template.md) 填写。
- 提交前跑 `npm run ci:local`：核心测试 + 仪表盘测试 + 构建 + 类型检查（`tsc --noEmit`），在临时用户目录与显式数据目录下执行，结束后清理。
- 改动了 dashboard/ 的话，在本地看板手动验证页面行为。
- 测试约定见 [README 开发节](README.md#开发) 与 [CLAUDE.md](CLAUDE.md)。
- PR 自动检查（pr-checks.yml）：纯文档改动跳过测试；代码改动跑同一个 `npm run ci:local` 聚合入口，包含完整前端测试。

## 依赖升级

- 核心零依赖是硬约束：根 package.json 的 `dependencies` 必须保持 `{}`，功能优先用 Node 内置模块（`node:sqlite`、`node:http`、`node:crypto`、`node:zlib` 等）实现。
- 仪表盘依赖升级单独开 PR，不与其他改动混在一起；`dashboard/package-lock.json` 一并提交。
- 升级 PR 里附 `npm ls --prefix dashboard` 的解析结果与 `npm run ci:local` 的运行结果。
- 不得引入会触发 npx 下载的行为：本地缺少运行时也不得自动下载依赖。

## 使用 AI

- 可以用 AI 辅助开发，但必须披露：工具名、模型版本、用途（发现问题 / 写代码 / 写测试 / 写说明）。
- 作者必须逐行理解全部改动并亲自验证，至少跑 `npm run ci:local`。
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
