<div align="center">

<img src="docs/images/app-icon.png" width="96" alt="">

# Token Lens

纯本地的 AI 编程工具 token 用量与花费统计

[![版本](https://img.shields.io/github/v/release/rumoii/token-lens?label=%E7%89%88%E6%9C%AC&color=2a8f7b)](https://github.com/rumoii/token-lens/releases/latest)
[![下载量](https://img.shields.io/github/downloads/rumoii/token-lens/total?label=%E4%B8%8B%E8%BD%BD%E9%87%8F&color=2a8f7b)](https://github.com/rumoii/token-lens/releases)
[![Stars](https://img.shields.io/github/stars/rumoii/token-lens?label=Stars&color=2a8f7b)](https://github.com/rumoii/token-lens/stargazers)
[![许可证](https://img.shields.io/github/license/rumoii/token-lens?label=%E8%AE%B8%E5%8F%AF%E8%AF%81)](LICENSE)
![系统](https://img.shields.io/badge/%E7%B3%BB%E7%BB%9F-Windows%20%C2%B7%20macOS-4b6b8a)
[![隐私](https://img.shields.io/badge/%E9%9A%90%E7%A7%81-%E7%BA%AF%E6%9C%AC%E5%9C%B0%20%C2%B7%20%E9%9B%B6%E9%81%A5%E6%B5%8B-4b6b8a)](PRIVACY.md)

**[下载](https://github.com/rumoii/token-lens/releases/latest)** · [安装指南](INSTALL.md) · [使用](#使用) · [隐私说明](PRIVACY.md) · [English](README.en.md)

</div>

Token Lens 是一个桌面应用。它读取 Claude Code、Codex、Kimi、Qwen Code 等 28 款 AI 编程工具写在本机的日志，算出每个工具、模型、项目、会话用了多少 token，按各模型的公开价估算值多少钱，还能看到每次请求要等多久才开始回复、回复得多快。不登录、不上传、没有遥测。

## 亮点

- **一处看全**：28 款工具的用量汇进同一个本地账本，按工具、模型、项目、会话、时间随意拆开，和上一期比多了还是少了。
- **数据不出本机**：只读日志里的用量字段，提示词、回复和代码不进账本，也不发出去；不修改这些工具的任何文件。
- **账记得准**：同一条记录重复读取不会重复计数；客户端清理了日志，已经记下的用量照样保留；按任何维度分组，各组之和都等于总数。
- **看得到快慢**：每次请求等了多久才开始回复、每秒出多少 token，按会话、按请求都能看。
- **给脚本和 AI 助手用**：随程序附带只读的 JSON 命令行 `token-lens-cli`，明细也能导出成 CSV 或 JSON。

## 功能

- **用量总览**：今天、本周、本月、昨天、上周、上个月、最近 7 天或 30 天，以及任意时段用了多少 token，约值多少，比上一期多了还是少了；点开能看到是哪些项目、工具或模型多了、少了；按小时或按天的趋势图，可切换看 token 或金额；一年的活跃热力图。
- **明细**：按时间、工具、模型、项目拆开看，可以叠加筛选，筛选项多时能搜索；每一行都能看到新输入、输出、读缓存、写缓存四类 token，也可以并排列出上一期和差额。
- **会话**：每个会话用了多少、按天怎么分布、用了哪些模型；能按项目、会话 ID、工具或模型搜索，按用量、金额、开始时间、最近活动或请求数排序。
- **请求计时**：首字（开始回复前要等多久）、速度（回复时每秒出多少 token）、平均速度（算上等待）。只有日志里记了时间的工具才有，缺的地方会写明原因。
- **工具**：全部支持的工具各去哪几个目录找日志、找到没有、没找到是没装还是没有权限；每个工具的日志怎么记、用真实日志还是样例日志核对过、有哪些已知限制。不想看的工具可以隐藏，只影响显示，照常记账。
- **同步状态**：同步中、第一次同步的进度、同步失败或有异常，都会在数据页顶部提示。
- **价格**：各模型的公开价、长上下文和分时段计价，按美元或人民币显示。金额只用来比较和感知，不是你的账单；用套餐的话，实际花费通常更低。
- **AI 热点**：20 个官方博客、更新日志和社区来源的新闻，程序开着时每 30 分钟刷新一次；已读和收藏只存在本机。不需要的话，可以在首次引导里勾选“只用本地统计”，或之后在设置里关掉，关掉后不再联网取新闻。
- **导出与命令行**：明细可以导出成 CSV 或 JSON；随程序附带的 `token-lens-cli` 用 JSON 输出用量、花费和会话，给脚本和 AI 助手用。
- **中文和英文界面**，默认跟随系统语言；深色模式；数字单位可选“万 / 亿”或“K / M / B”。
- **显示设置**：紧凑模式一屏看更多行；界面缩放 90%–125%，在系统缩放的基础上再调；打开时停在哪个时段；每周从周一还是周日开始。

## 截图

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshot-overview.png" width="420" alt="首页概览"><br>首页概览</td>
    <td align="center"><img src="docs/images/screenshot-detail.png" width="420" alt="明细：按项目拆开"><br>明细：按项目拆开</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshot-session-requests.png" width="420" alt="会话详情：每次请求"><br>会话详情：每次请求</td>
    <td align="center"><img src="docs/images/screenshot-sessions.png" width="420" alt="会话列表"><br>会话列表</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="docs/images/screenshot-overview-dark.png" width="420" alt="深色主题"><br>深色主题</td>
  </tr>
</table>

截图里的用量是合成的演示数据，项目路径均为虚构。

## 支持的工具

| 客户端 | source | 证据 | 备注 |
| --- | --- | --- | --- |
| Claude Code | claude | 实测·对账零差异 | 输入不含缓存读写；缓存写分 5m/1h 档计价 |
| Codex CLI | codex | 实测·对账零差异 | cached ⊂ input；rollout JSONL（含 .zst） |
| Qwen Code | qwen | 实测·逐字段对照 | 输入含缓存需扣减；输出并入 thoughtsTokens |
| Pi | pi | 实测·逐字段对照 | 会话头与用量不在同一行 |
| DeepSeek Harness (DSH) | dsh | 实测·与客户端自报对照 | 会话级累计快照，全量覆写 |
| Antigravity CLI (agy) | antigravity | 实测·与客户端自报对照 | 每个会话一个 SQLite；输入不含读缓存，输出含思考；不报告写缓存 |
| Grok Build CLI | grok | 有样本·待对照 | 仅 turn_completed 带用量 |
| Hermes Agent | hermes | 有样本·待对照 | 累计；两张表结构不同 |
| Aider | aider | 实验性·合成验证 | commit_hash 不作会话标识；只读取 ~/.aider.llm.history |
| Cline / Roo Code | cline | 实验性·合成验证 | 当前 Cline 与 Roo Code 的用量格式尚未接入，可能读不到 |
| CodeBuddy / WorkBuddy | codebuddy | 实验性·合成验证 | 第三方逆向依据；CLI projects 与桌面请求索引；输入扣缓存读，待真实样本 |
| Continue.dev | continue | 实验性·合成验证 | 单文件多轮 |
| GitHub Copilot | copilot | 实验性·合成验证 | data.db 只作一次性基线 |
| Cursor | cursor | 实验性·合成验证 | 内部 SQLite 结构随版本变化 |
| Gemini CLI | gemini | 实验性·合成验证 | 目录混有非用量 JSON |
| Block Goose | goose | 实验性·合成验证 | 两套 token 字段 |
| Kimi / Kimi Code | kimi | 实测·与客户端自报对照 | 目录层级不统一 |
| MiMo Code | mimo | 实验性·合成验证 | 按上游源码实现，待真实样本；删会话后已采集用量保留；Desktop 路径未核实 |
| MiniMax Code | minimax | 实验性·合成验证 | 按上游源码实现，待真实样本；rewind 或删会话后已采集用量保留 |
| ZCode | zcode | 实验性·合成验证 | 按上游源码实现，待真实样本；客户端保留 30 天，已采集用量保留 |
| Command Code | commandcode | 实验性·合成验证 | npm 1.88.2 v3 transcript；输入扣缓存读写，待真实样本 |
| AnythingLLM | anythingllm | 实验性·合成验证 | 桌面 SQLite；token 可能为估算，缓存未知；隐藏/删除不撤销已采集用量 |
| OpenClaw | openclaw | 实验性·合成验证 | 归档与活跃目录可能重复 |
| OpenCode | opencode | 实验性·合成验证 | v1/v2 表结构不同 |
| Kilo Code | kilo | 实验性·合成验证 | 只读新版 kilo.db；旧版 JSON 任务目录未接入 |
| OpenHands CLI | openhands | 实验性·合成验证 | 仅原生 CLI；无响应事件的用量跳过，SDK 自定义脚本、ACP 与远程 runtime 未接入 |
| Trae / Trae CN | trae | 实验性·合成验证 | JSONL id 语义未确认 |
| Zed | zed | 实验性·合成验证 | payload 可能是 zstd BLOB |

实测 = 用真实日志核对过（逐字段手核、与客户端自报的总量对照，或与账本对账）。有样本·待对照 = 有真实日志，但用量太少或没有可对照的数字。实验性 = 合成样本验证通过、还缺真实日志验收，欢迎反馈真实样本。各工具的字段含义和已知限制见 [适配器契约](docs/development/adapters.md) 与 [日志字段事实](docs/development/log-schemas.yaml)。

## 安装

从 [Releases](https://github.com/rumoii/token-lens/releases/latest) 下载对应系统的 zip，解压即用，不需要安装 Node、Python 或其他运行环境。同一个 Release 里的 `SHA256SUMS.txt` 可以用来确认下载完整。

- **Windows**：Windows 10 / 11，x64。解压后双击 `token-lens.exe`；文件夹里的 exe、DLL 和 `data/` 要放在一起。
- **macOS**：Apple 芯片（M 系列），macOS 12 或更新。解压后把 `Token Lens.app` 拖进「应用程序」再打开。

程序没有签名，第一次打开时 Windows SmartScreen 或 macOS 会拦一下。放行的步骤、怎么校验下载、怎么卸载，见[安装指南](INSTALL.md)。

## 使用

第一次打开时，Token Lens 会列出在这台电脑上找到的工具，点「开始统计」后才读取日志内容，第一遍会读完全部日志。之后每次打开都会同步一次，窗口开着时每 5 分钟同步一次，也可以随时点「同步用量」。关掉窗口程序就退出，不留后台进程，也不开机自启。

重复打开时只会激活已经开着的那个窗口。

### 导出和命令行

「明细」页下方的「导出」把当前筛选和分组存成 CSV 或 JSON，放进“下载”文件夹。项目默认只写名字，勾选「包含完整项目路径」才写路径。

`token-lens-cli` 和程序放在一起：Windows 是解压文件夹里的 `token-lens-cli.exe`，macOS 是 `Token Lens.app/Contents/MacOS/token-lens-cli`。它读同一个账本，每条命令输出一个 JSON 对象。

```sh
token-lens-cli status                          # 账本和上次同步
token-lens-cli summary --period week --compare # 本周用量、花费，和上周比
token-lens-cli breakdown --by model            # 按模型拆开
token-lens-cli sessions --sort cost --limit 10 # 最贵的 10 个会话
token-lens-cli sync                            # 同步一次
```

除了 `sync`，命令都只读账本，不联网，也不会触发同步；结果里的 `freshness` 写明数据是什么时候同步的。完整说明和退出码见 [docs/development/cli.md](docs/development/cli.md)。

## 工作原理

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/architecture-dark.svg">
  <img src="docs/images/architecture.svg" alt="各工具的本机日志只读进入 Rust 适配器，写进 SQLite 账本，再由 Flutter 界面显示；联网只有 AI 热点、汇率和检查更新三处，结果只给界面用，不进账本。">
</picture>

- 界面是 Flutter，统计、计价和新闻刷新都在随程序分发的 Rust 库里，通过 flutter_rust_bridge 在进程内调用；没有本地网页服务，也不用 WebView。
- 同一条记录重复读取不会重复计数；日志被客户端清理后，已经记下的用量仍然保留。账本每一列的含义和不变式见 [docs/development/ledger.md](docs/development/ledger.md)。
- 金额以整数微美元（USD × 10⁶）存储，计价规则见 [docs/development/pricing.md](docs/development/pricing.md)。
- 每次请求的计时单独存放，不影响用量和金额，口径见 [docs/development/stats.md](docs/development/stats.md)。

| 目录 | 内容 |
| --- | --- |
| `app/` | 桌面应用：Flutter 界面（`app/lib/`）和 Rust 核心（`app/rust/`） |
| `docs/development/` | 账本、适配器、日志字段、统计、计价、新闻、命令行和发布的规格 |
| `docs/decisions/`、`docs/releases/` | 设计决策和版本说明 |
| `scripts/` | 开发运行、检查、演示数据和发布校验脚本 |

## 从源码构建

需要 Flutter 3.47.9、Rust 1.98.0；Windows 还要 Visual Studio 的 C++ 桌面开发组件和创建符号链接的权限（打开 Windows 的开发者模式即可），macOS 要 Xcode。

```sh
cd app
flutter pub get --enforce-lockfile
flutter build windows --release   # 或 flutter build macos --release
```

产物在 `app/build/windows/x64/runner/Release/`（macOS 是 `app/build/macos/Build/Products/Release/Token Lens.app`）。开发运行必须同时隔离测试数据目录和日志根目录，检查命令、代码生成和发布流程见 [app/README.md](app/README.md#开发与检查) 和[贡献指南](CONTRIBUTING.md)。

## 升级与数据

- 升级时关掉 Token Lens，用新版替换程序文件（Windows 是解压出的整个文件夹的内容，macOS 是 `Token Lens.app`）。用量数据不在程序文件夹里，替换不会丢。
- 新版需要升级账本结构时，第一次打开会自动迁移，迁移前在数据目录里存一份升级前的完整备份 `ledger-v<旧结构版本>-….db`。
- 新版打开过以后，旧版程序会拒绝打开升级后的账本。确实要退回旧版，按 [app/README.md](app/README.md#运行与回退) 的「运行与回退」用自动备份恢复，不要直接换回旧的程序。
- 想自己备份：关掉 Token Lens，复制整个数据目录（位置见[数据与隐私](#数据与隐私)）。`ledger.db` 旁边的 `ledger.db-wal`、`ledger.db-shm` 要一起复制。

## 文档

- [安装指南](INSTALL.md)
- [隐私说明](PRIVACY.md)
- [贡献指南](CONTRIBUTING.md)、[新增一个工具来源](docs/development/adding-a-source.md)
- [安全政策](SECURITY.md)
- 开发规格（简体中文）：[账本契约](docs/development/ledger.md)、[统计与计时](docs/development/stats.md)、[适配器契约](docs/development/adapters.md)、[日志字段事实](docs/development/log-schemas.yaml)、[定价](docs/development/pricing.md)、[新闻来源](docs/development/news.md)、[检查更新](docs/development/update.md)、[命令行与导出](docs/development/cli.md)、[桌面应用的技术决定](docs/development/desktop.md)、[发布流程](docs/development/release.md)
- [设计决策](docs/decisions/README.md)
- [版本说明](docs/releases/README.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)

## 数据与隐私

- **只读本机日志**：在本机读取并解析各工具的日志，只提取用量元数据（四类 token、模型、时间、会话、项目路径）；日志里的提示词、回复、代码和凭据不会写进账本，也不会发出去。不修改这些工具的任何文件。
- **数据只在本机**：用量、偏好和新闻缓存都在系统的应用支持目录下的 `data` 文件夹里：Windows 上是 `%APPDATA%\Token Lens\Token Lens\data`，macOS 上是 `~/Library/Application Support/io.github.rumoii.token-lens/data`。不再需要时整个删掉即可。
- **会联网的只有三件事**：AI 热点开着时按上面的时间刷新新闻来源；在设置里点「更新汇率」时取一次美元兑人民币汇率；每天最多一次向 GitHub 查询有没有新版本（可在设置里关掉，有新版只提示，不自动下载）。请求不带账号、凭据或用量数据。来源清单和请求方式见 [docs/development/news.md](docs/development/news.md)，检查更新见 [docs/development/update.md](docs/development/update.md)。
- 没有账号、上传、遥测或第三方分析。完整说明见 [隐私说明](PRIVACY.md)。

## 贡献

欢迎 Issue 与 PR。提交前请读 [贡献指南](CONTRIBUTING.md)。工具日志格式对不上、或者你有某个实验性工具的真实日志样本，特别欢迎反馈；样本只需要和用量有关的几个字段，提交前请删掉提示词、回复、路径和账号信息。

## Star 趋势

<a href="https://star-history.com/#rumoii/token-lens&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=rumoii/token-lens&type=Date&theme=dark">
    <img alt="Star 趋势" src="https://api.star-history.com/svg?repos=rumoii/token-lens&type=Date" width="600">
  </picture>
</a>

## 致谢

Token Lens 使用了 [Flutter](https://flutter.dev/)、[Rust](https://www.rust-lang.org/)、[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)、[SQLite](https://sqlite.org/)（经由 [rusqlite](https://github.com/rusqlite/rusqlite)）、[Tokio](https://tokio.rs/)、[reqwest](https://github.com/seanmonstar/reqwest) 和 [ruzstd](https://github.com/KillingSpark/zstd-rs)。第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

各 AI 编程工具的名称和图标归各自的所有者，只用来在界面里标出对应的工具。

## 名字

AI 工具各自写下日志，用量散落各处，难见全貌。Token Lens 像一片镜片，把零碎的记录收拢到一处，调准焦距——token 都去了哪里，一眼就能看清。

## 许可

[MIT](LICENSE)，`Copyright (c) 2026 rumoii`。第三方组件的许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。
