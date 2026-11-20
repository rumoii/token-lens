# 新增一个工具来源

本文写给要让 Token Lens 认识一款新 AI 编程工具的贡献者。新来源只写进桌面版的 Rust 核心（`app/rust/`）；旧版 Node 工具已经冻结，不再接收新来源。

## 开始之前

- 按 [CONTRIBUTING.md 的「开发快速开始」](../CONTRIBUTING.md#开发快速开始)准备环境，并先在 `app/` 运行一次 `flutter pub get --enforce-lockfile`。新的 clone 或 worktree 没有这一步，检查会在 Flutter 分析阶段报出上万条「未定义」错误，和你的改动无关。
- 先读这三份，本文不重复它们的内容：
  - [`specs/adapters.md`](../specs/adapters.md) 的「通用契约」「稳定身份」和「验收口径」末尾的 7 个用例；
  - [`specs/log-schemas.yaml`](../specs/log-schemas.yaml)：每个来源的日志位置和字段位置。新来源也要在这里登记；
  - [`CLAUDE.md`](../CLAUDE.md) 的「Ledger contract」：账本列的含义（包括 `provider`），以及「未知不是零」这类不变式。

## 先回答这几个问题

在写代码之前，把下面这些答案连同依据写进 `specs/log-schemas.yaml` 的新条目里。答不上来的，先去找证据，不要猜。

| 问题 | 要写清的 | 常见的坑 |
| --- | --- | --- |
| 日志在哪？ | Windows、macOS、Linux 的默认位置；客户端支持的覆盖环境变量 | 只写自己电脑上的路径；把没有依据的旧路径也加进去 |
| 一条记录是什么？ | 一次请求（`event`），还是会话累计快照（`cumulative`） | 把会改写的会话总数当成事件，重复采集时越加越多 |
| 身份怎么取？ | 优先用客户端给的请求或消息 ID | 把 token 数放进身份；用文件路径做身份，文件一移动就重复计数 |
| 时间是哪个时间？ | 请求发生的时间，转成 UTC | 用文件修改时间；把本地时间当成 UTC |
| 四类 token 谁包含谁？ | 输入是否已含读缓存、写缓存；输出是否含思考 token | 客户端的输入包含缓存时没有扣掉，导致重复计数 |
| 项目从哪里来？ | 日志里明写的工作目录 | 从日志文件路径或目录名猜项目。日志没写就存 `NULL` |
| 模型和 provider | 日志里明写的字段 | 从模型名推 provider；缺失时填默认模型 |
| 证据等级 | A：用真实日志逐项对过客户端自报的用量；B：只按上游源码或第三方资料实现，用合成数据验证 | 没对过真实样本却标 A |

未知就存 `NULL`，不要写成 0。四类 token 落库后互不重叠，扣减由适配器负责，查询层不做调整。

**条目格式**：照 `commandcode` 或 `antigravity` 这类较短的条目写。新条目的键用来源 ID（老条目有些用了别的名字，不必效仿）。至少要有 `description`、`evidence`、`locations`、`format`、`key_fields`（`identity`、`session_id`、`project_key`、`model`、`provider`、`timestamp`、`usage` 四项）；有特殊的发现规则、覆盖变量或保留期时，再加 `discovery_pattern`、`environment`、`retention`。

## 要改的地方

下面以来源 ID `acme` 为例。ID 用小写字母，一旦发布就不再改，因为它会写进用户的账本。

### 1. 规格和来源总数
- `specs/log-schemas.yaml`：新增一节，见上面的条目格式。
- `specs/adapters.md`：在契约表里加一行；有特殊口径的（例如输入含缓存、只报告累计值）在正文里写一段。
- **来源总数**散在好几个文件里，全部要加一。先用当前总数搜一遍，再逐处判断：

  ```sh
  rg -n "28" README.md README.en.md CLAUDE.md AGENTS.md app/README.md specs/adapters.md specs/stats.md
  ```

  - 要改：两个 README、`CLAUDE.md`、`AGENTS.md`、`app/README.md` 里的支持来源数；`specs/adapters.md` 的标题、字段表里「source N 组之一」、契约表小节标题，以及「其余 N 组本机无样本」这类算出来的数；`specs/stats.md`「工具」页那一条。
  - **不要改**：`specs/stats.md` 里「27 个全部迁移」「27 个来源的扫描根和模式」这类句子，27 指从旧版 Node 迁过来的那一批，不随新来源变化。

### 2. 发现日志：`app/rust/src/stats/discovery.rs`
- **`scan_roots`**：登记 `acme` 的扫描根目录。「工具」页显示的日志位置、诊断导出里的路径都来自这里。
- **`discover_profiled`**：
  - 用现有的 `glob` 找文件，最后 `add(&mut scan, "acme", files)`；
  - 跳过不含用量的同目录文件，例如 Command Code 跳过 `.checkpoints.jsonl`；
  - **顺序**：各来源 `add` 的先后必须和 `PARSER_REV` 里的顺序一致，`service.rs` 的测试会逐项比较。新来源在两处都追加到末尾。
- 路径只从 `home` 和 `env`（`Environment`）推出，不直接读进程环境变量。开发和测试时，`TOKEN_LENS_PREVIEW_HOME` 会把 `home` 换成合成目录，所有位置必须跟着换，这样才读不到开发者本机的真实日志。
- 用到 `APPDATA`、`LOCALAPPDATA`、XDG 目录时，沿用文件里现成的 `windows_app_data`、`xdg_data` 等函数。
- 如果客户端支持覆盖变量（像 `OPENCODE_DB`），要通过 `env.get` 或 `env.absolute` 读取。预览模式的 `Environment::preview` 会清空全部变量，所以覆盖变量在开发和测试中自动不生效；不要绕过 `env` 直接读进程环境。

### 3. 解析：`app/rust/src/stats/adapters/acme.rs`
- 新建文件，通常只需对 `mod.rs` 暴露一个 `parse` 函数，返回 `Result<Vec<Value>>`。
  - 文本日志（JSONL、JSON）收到的是文件字节；
  - SQLite 来源收到的是文件路径，只读打开。
- 先看现有的来源怎么写，再动手：
  - 简单的 JSONL 事件可以参考 `commandcode.rs`；
  - 会话快照可以参考 `dsh.rs`；
  - SQLite 来源可以参考 `goose.rs`、`zcode.rs`。
- 能复用的工具函数在 `lines.rs`、`num.rs`、`project.rs`：
  - `lines`：逐行解析 JSONL，坏行记入 `bad_lines`；
  - `token_of`：读取 token 字段，非法值记入 `bad_fields` 并返回 `None`；
  - `event`：生成一条带全部必需字段的事件记录。它还会带上 `timestamp` 和 `cache_creation_tokens` 两个旧版字段，入账不读它们，新来源照 `commandcode.rs` 删掉即可；
  - `empty`：四类都是零或都未知时跳过，并计入 `zero_usage`；
  - `project`：规范化工作目录；
  - `jscompat::normalize_timestamp`：把秒、毫秒或 ISO 字符串转成 UTC ISO 字符串。
- 只有日志里明写了 provider 时，才在记录里加 `provider` 字段。
- `notes` 只有四个计数：`bad_lines`、`bad_fields`、`bad_times`、`zero_usage`，它们会出现在同步结果和诊断里。宁可跳过一条并计数，也不要猜一个值。常见的边界照现有来源处理：
  - 时间缺失或无法解析：计 `bad_times`，整条跳过。
  - 输入含缓存、扣完是负数：计 `bad_fields`，输入存 `NULL`。
  - 缓存字段缺失：只有确认客户端缺省就表示「没有缓存」时才按 0 扣，并写进 `log-schemas.yaml`；不能确认时输入存 `NULL`。
  - 同一身份在文件里重复：只保留一条，没有专门的计数，在规格里写明保留哪一条。
- 不读取提示词、回复正文和凭据，只取用量所需的字段。

### 4. 登记：`app/rust/src/stats/adapters/mod.rs`
- 加 `mod acme;`。
- 在 `parse_profiled` 里分派：
  - 文本来源加进下面那个 `match source`；
  - SQLite 来源加进上面那个，并加进 `sqlite_only`。
- 日志文件可能不存在、不存在时应该当作没有记录的来源，加进 `parse_profiled` 里那组 `!file.exists()` 判断。
- 解析要读同目录的另一个文件时（例如 Cline 的 `ui_messages.json`），在 `sidecar` 里登记，文件缓存才会在旁文件变化时重新解析。
- 在 `PARSER_REV` 末尾加 `("acme", 1)`。
  - 以后只要这个来源产出的值、身份或时间有任何变化，就把它加一，否则用户账本里的旧行不会更新。
  - 请求计时用另一个版本号 `TIMING_REV`，只在接入计时时登记，见 `specs/adapters.md`「E4a 请求计时」。
- SQLite 来源不参与文件缓存，还要把它加进 `specs/stats.md`「E5」一节里的 SQLite 来源清单。

### 5. 名称、说明和图标
- **`app/rust/src/stats/output.rs`** 的 `tool_name`：显示名，命令行和导出会用到。
- **`app/rust/src/stats/source_notes.rs`**：
  - `EVIDENCE` 只登记需要特别标注的来源，没登记的一律按 B 显示。证据 A 的来源要登记；B 可以登记也可以不登记，登记了会让测试里的来源计数加一（见下面「测试」第 4 条）。
  - `SOURCE_LIMITS` 写这个来源的口径说明，每条五列：中文标题、中文说明、影响、英文标题、英文说明。影响只有两种：`handled` 表示适配器已经处理好，用户不用操心；`affects` 表示会影响用户怎么读数字。「工具」页会显示它们。
- **`app/lib/stats/logic/tools.dart`**：界面上的名称和图标。
  - 有授权可用的图标时，放进 `app/assets/tool-logos/`，`logo` 写文件名；
  - 没有就把 `logo` 写成 `null`，界面会显示首字母。
  - 不要从别的产品抓取图标。

### 6. 价格（只在出现新模型时）
新来源用的模型如果价格表里没有，账本照常记 token，金额显示「未计价」，这不影响加来源。要补价格，改 `app/rust/src/stats/pricing-catalog.json`，规则见 [`specs/pricing.md`](../specs/pricing.md) 第 9 节。价格改动单独开 PR。

## 测试

原有 27 个来源的测试对照的是旧版 Node 生成的数据（`test/fixtures/`、`app/rust/tests/golden/`）。新来源只存在于 Rust，**不要改这些 golden 文件**，而是自带合成数据。做法照 Antigravity：

1. **合成样本**：写一个 `adapters/acme_tests.rs`，在 `mod.rs` 里用 `#[cfg(test)] pub(crate) mod acme_tests;` 引入，提供 `seed(home)`，在临时目录里写出最小但完整的日志。
   - 格式照真实日志，内容全部虚构。
   - 覆盖 `specs/adapters.md` 末尾的 7 个用例。只产出逐请求事件的来源，第 4 条「累计快照变化」不适用；客户端没有独立的自报总量时，第 7 条不适用。不适用的在 `specs/adapters.md` 里写明原因，照 Command Code 那段的写法。
2. **精确预期**：对 `seed` 产出的日志调用 `parse`，逐字段断言记录，包括 `record_key`、时间、四类 token 和 `notes` 的计数。
3. **全量同步**：在 `mod.rs` 的 `all_registered_sources_sync_and_repeat` 里调用 `acme_tests::seed(&home)`。这个测试会断言每个登记在 `PARSER_REV` 里的来源都同步出了记录，而且第二次同步不新增。
4. **随来源总数变化的断言**，要一起改：
   - `app/rust/tests/s3.rs`：`discovery.tools.len()` 和同步进度的 `progress.total` 两处，都是来源总数；
   - `app/rust/src/stats/service/d33_tests.rs` 的 `RUST_ONLY_SOURCES`：加上 `"acme"`。桌面版的发现数量和 `EVIDENCE` 计数要和固定的 Node golden 对照，这个常量用来扣掉只存在于 Rust 的来源，所以不用改 golden 文件；
   - 如果在 `EVIDENCE` 里登记了新来源，`app/rust/src/stats/service.rs` 里 `known_sources` 的断言也要加一。
5. **发现**：
   - 默认路径：加进 `discovery.rs` 的 `platform_tests::macos_roots_and_override_rules`；
   - 预览隔离：确认设置预览主目录后不会读到主目录以外的位置，写在 `app/rust/src/api/stats_discovery_tests.rs`，照 `antigravity_s0a_preview_ignores_outside_home` 写一个。
6. 改了 `PARSER_REV` 的老来源，同样要加测试，说明哪个值变了。

先写测试、看它失败，再写解析。然后从仓库根目录跑：

```sh
python scripts/desktop-dev.py check
```

这是桌面 CI 的同一入口，会检查 Rust 和 Flutter 格式、跑全部测试、核对第三方声明和锁文件。只想快速跑 Rust 部分时用 `--only rust`。

## 用真实日志核对（证据 A）

合成数据只能证明解析逻辑和你的理解一致，不能证明你的理解是对的。要标证据 A，需要用真实日志对一次：
- 用客户端自己报告的用量（会话总计、`/usage` 一类的输出、JSON 导出）逐项对照 Token Lens 记下的四类 token。
- 在 `specs/adapters.md`「证据现状」里写清对照了什么、结果如何。
- 真实日志只在你自己的电脑上用，**不要提交**。需要夹具时，只保留身份、时间和用量字段，删掉正文、路径和用户名，就像 `test/fixtures/pi/` 那样。

## 提交 PR 前
- `python scripts/desktop-dev.py check` 通过。
- `specs/log-schemas.yaml`、`specs/adapters.md` 和各处来源总数都已更新。
- PR 描述里写清证据等级、核对过的客户端版本，以及没有核对的部分。
