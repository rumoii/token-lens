# 统计迁移（D3）

## 阶段与边界

D3 把统计内核和看板从 Node/React 移到桌面预览的 Rust 核心和 Flutter 界面。旧版在 D4 切换验收前保持可用，并且是 D3 的行为基线：仓库 `1ce3446` 的 `src/core`，运行时 Node v24.22.1，账本 schema v5。

- 账本：Rust 原样沿用 schema v5（[CLAUDE.md](../CLAUDE.md)「Ledger contract」）。`record_key`、`content_hash`、价表版本与旧版逐字节一致，新版能直接打开旧版账本的副本。
- 适配器：27 个全部迁移，分三批（见「子阶段」）。
- 界面：照现有看板的结构搬（总览、明细、会话、来源、设置与价格），只有和现有界面不同或拿不准的地方先做原型。
- 数据：D3 的账本放在预览目录，D3 期间从不打开、读取或写入 `~/.token-lens`，也不读 `TOKEN_LENS_DATA_DIR`、`DB_PATH`。真实账本的副本迁移和切换属于 D4，每一步单独确认。
- 联网：统计不联网。汇率更新沿用旧版的规则：只在用户点击时请求（[features.md](features.md) G14–G16）。

## 兼容基线

### 必须一致

同一批输入文件、同一个路径字符串、固定的 `now` 和时区偏移下，新旧两版必须得到一样的结果：

- 适配器产出：记录顺序、每个字段（区分缺失和显式 NULL）、`replaces` 的顺序、notes 计数。
- 身份：`record_key`、`content_hash` 的规范输入字节和输出，以及 `_lines.fileTag`、OpenClaw 内容身份、`PRICE_VERSION`。
- 账本：`usage_records` 每列（`id`、`ingested_at` 除外，`superseded_by` 按它指向的 `record_key` 比较），每次批量入库的计数和异常。
- 计价：`cost_micros`、`price_source`、四个整数分项。
- 查询：在显式身份上排序后，返回结构一致。旧版本身没有确定 tie-break 的列表，例如 sessions 里同一时刻、不同 source 的会话，不比较并列项的先后。

### 必须复现的旧行为

这些都已由只读梳理核实，`file:line` 指旧版源码。

| 项 | 规则 | 出处 |
| --- | --- | --- |
| `content_hash` | 11 个字段：`kind\|\|'event'`、`model\|\|''`、四类 token、`observed_at\|\|''`、`ended_at\|\|''`、`session_id\|\|''`、两个缓存写分档。token 缺失或 NULL 写字面 `null`，其余按 JS 数字转字符串。只有 provider 不为 NULL 时才追加 provider 原值（空串也追加）。各段之间用 `0x1f` 连接，UTF-8 编码后做 SHA-256，取前 32 个 hex 字符 | `src/core/db/write.js:22–36` |
| 已有行的 `ended_at` | 新值为 NULL 时，先继承旧值，再计算 hash 和价格；`project_key` 用 `coalesce` 保留旧值；其他字段可以被 NULL 覆盖 | `write.js:152,232–236` |
| 文件身份 | `f` + 对原始路径字符串的 UTF-8 做 SHA-256，取前 12 个 hex 字符。路径不做 resolve、不转小写、不改斜杠；Codex 只去掉末尾大小写敏感的 `.zst` | `src/core/adapters/_lines.js:54–55`；`codex.js:57` |
| `PRICE_VERSION` | 对 `[entries.map(e => [id, perMTok, verifiedAt, tier, tiers??null, timeOfDay??null, billing]), localProviders]` 做 JS `JSON.stringify`（键序按插入顺序），SHA-256 后取前 16 个 hex 字符。当前值 `7a41a11013b21c6b` | `src/core/pricing/catalog.js:457–464` |
| 时间规范化 | 所有 falsy 值都算 NULL；数字小于 1e12 按秒，否则按毫秒；其余交给 JS `Date` 宽容解析，**不带时区的日期时间按本机本地时间解释**，仅日期的按 UTC；输出 `toISOString()`（UTC，毫秒精度） | `_lines.js:66–69` |
| 数字 | 合法值是非负整数，或 trim 后的纯 ASCII 数字串；首选别名非法时不回退到下一个别名；`minus` / `plus` 各有 NULL 规则；有几个适配器的扣减结果为负时写 NULL，不截到 0 | `src/core/adapters/_num.js:34–92` |
| JSON | 重复键取最后一个；对象键按 JS 枚举顺序（整数键按数值升序在前，其余按插入顺序）。这会影响 OpenClaw 的身份哈希和 Cursor、Zed、OpenHands 的位置序号 | `openclaw.js:48–51` 等 |
| 跨文件副本 | 同一 source、同一 key 的 event：取所含记录中最早 `observed_at` 最小的文件（字符串比较），相同时按路径的 `localeCompare`（ICU 默认排序）；`cumulative` 不参与 | `src/core/ingest.js:129–169` |
| 写入分支 | 新增、恢复、relabel、touch、event 覆盖（不检查单调）、cumulative 下降（仅在 `parser_rev` 不同时接受）、`replaces`、按文件停用、`vanished`，计数口径照旧 | `write.js:221–334` |
| 计价 | 费率取 `round(perMTok×1e6)`，每个分项先截断，再四项相加；两个缓存写分档各自截断；本地提供方按小写精确匹配，四个分项都是 0；峰谷时段用固定 UTC+8 | `src/core/pricing/engine.js:14–169` |
| 时间桶 | 用调用方给的一个固定偏移切所有历史（不按历史日期分别处理 DST）；`cumulative` 只有在起止落在同一个桶时才分配到该桶 | `src/core/db/read.js:7–50`；`src/core/api/v1/common.js:12–25` |
| SQLite 外部库 | 只读打开，`busy_timeout=3000`、`query_only=ON`，不用 `immutable`；打开失败传播为文件级 `read_failed` | `src/core/adapters/hermes.js:33–35` 等 |
| 采集锁 | `<data-dir>/sync-lock.db`：单独连接，`busy_timeout=0`，持有 `BEGIN IMMEDIATE`；存在 `sync.lock` 时拒绝；从发现一直持有到账本关闭 | `src/core/sync-lock.js` |

### 允许的差异

下面这些不追求一致，要在 Rust 代码注释和本节里登记：

1. **发现只收文件**。旧版给 `fs.globSync` 传了 `nodir`，但这个选项实际不起作用（`src/core/discovery.js:16–19`），扩展名匹配的目录也会进入结果，然后以 `read_failed` 失败。新版跳过目录。这不影响任何记录。
2. **异常输入**。只要求在所有夹具和本机真实日志里出现过的形状上一致。超过 2^53 的整数、溢出成 Infinity 的超长数字串、`2026-02-30` 这类日历溢出、ISO 以外的日期写法，Rust 可以和旧版不同，但必须记 `bad_fields` 或 `bad_times`，不能静默写入别的值。D3.5 用真实日志确认这些形状不存在；如果出现，就把 Rust 改到和旧版一致。
3. **旧版文档与代码不一致的地方以代码为准**，例如 `specs/adapters.md` 里 Claude 的旧键写法、Grok/Aider/Goose/Zed 在 `log-schemas.yaml` 里的描述。迁移只搬现状，不修复字段语义；语义修复等真实样本，并且要升 `PARSER_REV`。

D4 切换以后才考虑的修复（D3 不做）：时间桶按历史日期分别处理 DST；`pricing_snapshot` 只存 `{version}`、不能按旧版本重新估值（`write.js:481–485`）；会话详情默认粒度三处不一致（`read.js:587`、`api/v1/sessions.js:47`、`api/router.js:33`）。

## Rust 布局

统计代码放在 `app/rust/src/stats/`，和新闻代码互不依赖：

| 模块 | 职责 | 对应旧版 |
| --- | --- | --- |
| `jscompat` | JS 数字转字符串、`Date` 宽容解析、JSON 键序、`localeCompare`、`encodeURIComponent` | 散在各处 |
| `ledger/open` | 打开、PRAGMA、v1→v5 迁移、拒绝更高版本 | `db/open.js` |
| `ledger/write` | 入库分支、文件停用、`ingest_runs`、重新计价、legacy 导入 | `db/write.js` |
| `ledger/read` | 聚合、分组、时间桶、会话、来源、价格标记 | `db/read.js` |
| `pricing` | 价表数据、规范化、分档、峰谷、计价、显示用舍入 | `pricing/*.js` |
| `lock` | `sync-lock.db` 协议 | `sync-lock.js` |
| `discovery` | 27 个来源的扫描根和模式 | `discovery.js` |
| `adapters/<source>` | 每个客户端一个文件，加共用的 `lines`、`num`、`project`、`zstd` | `adapters/*.js` |
| `ingest` | 发现 → 解析 → 跨文件副本 → 入库 → 重新计价 | `ingest.js` |
| `service` | 各接口的参数、默认值、格式化 | `api/v1/*.js` |

价表在 D3 期间有两份，JS 和 Rust 各一份。Rust 的单元测试固定 `PRICE_VERSION` 必须等于旧版的值；D4 之前改价必须两边一起改，测试会拦住只改了一边的情况。

## 数据目录与采集

- 统计账本：`<预览目录>/ledger.db`，锁文件是同目录的 `sync-lock.db`。预览目录沿用新闻用的规则（`TOKEN_LENS_PREVIEW_DATA_DIR` 或应用支持目录），D3 不读旧版的数据目录变量。
- 日志根目录：默认取系统用户目录。为了测试和对拍，可以用 `TOKEN_LENS_PREVIEW_HOME` 指向别的根目录，`APPDATA`、`LOCALAPPDATA`、`XDG_DATA_HOME` 和各客户端自己的覆盖变量按旧版规则读取。测试一律使用合成的根目录。
- 采集时机照旧：窗口打开后采集一次，开着时每 5 分钟一次，另有手动同步；撞上锁就跳过这一次。关窗就停止采集，进行中的事务回滚，已经提交的文件保留。
- 读取客户端日志只读；外部 SQLite 不做 checkpoint，也不加 `immutable`。

## FFI

`StatsClient` 对应旧版看板在用的接口，参数和字段名沿用 `/api/v1`（[api-v1.md](api-v1.md)），只是改成类型化的结构，不再经过 HTTP：

| 方法 | 旧接口 | 用到它的界面 |
| --- | --- | --- |
| `summary` | `/usage/summary` | 总览、明细、引导 |
| `timeseries` | `/usage/timeseries` | 总览、明细 |
| `matrix` | `/usage/matrix` | 总览、明细 |
| `breakdown` | `/usage/breakdown` | 总览、明细、来源、设置、会话 |
| `sessions`、`session_detail` | `/sessions`、`/sessions/detail` | 总览、会话 |
| `sources` | `/sources` | 总览、来源、会话 |
| `discovery` | `/discovery` | 引导 |
| `pricing` | `/pricing` | 总览、设置 |
| `health` | `/health` | 设置 |
| `sync` | `POST /sync` | 引导、来源、定时采集 |

- 金额在 FFI 上用整数 micro-USD 传递，界面显示用的六位小数字符串和低精度最大余数分配由 Rust `pricing` 统一给出，Dart 不自己算钱。
- 时区：Dart 传当前的 UTC 偏移分钟数，Rust 用它切所有历史，和旧版一致。快照里的时区名先读 `TZ`，没有再调用系统自带的 ICU（Windows `icu.dll`、macOS `libicucore`），不打包 ICU；macOS 上的链接和运行还没验证。
- 不迁移：`/usage/unallocated`（看板没用）、`POST /pricing/refresh`（旧版就是 501）、HTTP 边界（gate、token、port）、CLI。
- 并发：同一时间只有一个采集在跑；查询可以和采集并发，读的是已提交的数据。

## 对拍

- 生成器 `scripts/parity/` 调用旧版的生产入口（`adapters[source]`、`payloadHash`、`fileTag`、`Ledger`、`read`、各个 service），固定 `now`、时区和路径字符串，输出 UTF-8 JSONL。每行的 `type` 是 `adapter_record`、`identity`、`batch`、`ledger_row`、`price`、`query`、`run` 之一，字段顺序固定，NULL 显式写出。
- 夹具：现有的真实裁剪样本（codex、qwen、pi），加上把各测试里内联构造的合成输入整理成的静态文件，放在 `test/fixtures/`。
- 旧版输出提交到 `app/rust/tests/golden/`。Rust 测试读同一批夹具，输出同样的 JSONL 并逐行比较；身份和金额按字节比较，没有确定顺序的查询先按身份排序再比较结构。
- 时钟：旧版直接读 `Date` 和 SQLite `unixepoch()`，没有注入点。生成器用 Node 内置 `node:test` 的 `mock.timers` 只冻结 `Date`（固定 `2026-01-15T12:00:00.000Z`；主时区 `Asia/Shanghai`，另有 UTC，Date 兼容表还含 `America/New_York`），这是生成器里唯一允许的替换，不改 `src/core`。Rust 凡是读当前时间的地方都经可注入的时钟。
- 只有四个字段写成 `"<volatile>"` 不比较：`usage_records.ingested_at`、`legacy_records.imported_at`、`pricing_snapshot.created_at`（SQLite 默认值）和 `runIngestion` 的 `durationMs`。`snapshot.generated_at`、`ingest_runs.started_at` / `finished_at`、滚动 7/30 日、`pricing_snapshot.verified_at` 由冻结的时刻决定，严格比较。
- 旧版改了行为就重新生成 golden，提交里要说明原因。
- D3.5 真实日志对拍：只读本机客户端日志，旧版和新版各写一个临时账本，逐行比较。报告放在仓库外，不提交。

## 子阶段

每个子阶段做完都停下来评审。新的 Rust 依赖开工前列出名称、用途和缓存位置，经批准再装（预计有 rusqlite bundled、sha2、zstd、文件匹配，`localeCompare` 是否需要 ICU 排序库由 D3.1 评估）。

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| D3.1 | `jscompat`、账本打开/迁移/写入、计价、锁、`ingest`，claude 和 codex（含 zstd 多帧）的发现与适配器，`summary` 和 `breakdown`，一个最简的 Flutter 总览页 | 生成器和 golden 就位；两个来源的适配器、身份、账本行、计价、两个查询全部和 golden 一致；在旧版 v1–v4 账本的合成副本上迁移，结果与旧版一致；Rust/Flutter 全部检查通过 |
| D3.2a | 第二批 14 个：qwen、dsh、grok、aider、pi、cline、gemini、openhands、continue、trae、openclaw、kimi、codebuddy、commandcode | 每个来源都有静态夹具和 golden，逐条一致 |
| D3.2b | 第三批 11 个：hermes、cursor、opencode、kilo、goose、zed、copilot、mimo、minimax、zcode、anythingllm | 同上；SQLite 夹具包括 WAL 状态和打开失败两种情形 |
| D3.3 | 其余查询：时间桶、`unallocated`、分组矩阵、会话、来源检查、价格标记、`legacy_records` 计数、`lastRun` | 查询 golden 一致；分组之和、各时间桶加 `unallocated` 都等于总计 |
| D3.4 | 完整统计界面：总览、明细筛选、会话、来源、设置与价格、引导；配色定案后再落地 | 和旧看板逐页截图对照；Flutter 测试覆盖筛选、空态、未知值、未定价 |
| D3.5 | 真实日志对拍和资源占用测量 | 两个临时账本逐行一致，或者每一处差异都已解释并处理；同一份数据下记录旧版和新版的内存与启动时间 |

D4 再做：复制真实账本，在副本上由新版打开、全量采集，证明重复采集不新增行、金额不变，经用户确认后切换发行；旧库保留，供旧版回退。
