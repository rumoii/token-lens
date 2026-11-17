# 统计迁移（D3）

## 阶段与边界

D3 把统计内核和看板从 Node/React 移到桌面预览的 Rust 核心和 Flutter 界面。旧版是 D3 的行为基线：仓库 `1ce3446` 的 `src/core`，运行时 Node v24.22.1，账本 schema v5。

- 账本：D3 沿用 schema v5，E4a 桌面版在保留用量表的基础上升到 v6（见下文）（[CLAUDE.md](../CLAUDE.md)「Ledger contract」）。`record_key`、`content_hash`、价表版本与旧版逐字节一致，新版能直接打开旧版账本的副本。
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
2. **异常输入**。只要求在所有夹具和本机真实日志里出现过的形状上一致。超过 2^53 的整数、溢出成 Infinity 的超长数字串或外部 SQLite 的 REAL、`2026-02-30` 这类日历溢出、ISO 以外的日期写法，Rust 可以和旧版不同，但必须记 `bad_fields` 或 `bad_times`，不能静默写入别的值。D3.5 已确认这些形状未在本机真实日志中出现（见「对拍」）；后续如果出现，就把 Rust 改到和旧版一致。
3. **旧版文档与代码不一致的地方以代码为准**，例如 `specs/adapters.md` 里 Claude 的旧键写法、Grok/Aider/Goose/Zed 在 `log-schemas.yaml` 里的描述。迁移只搬现状，不修复字段语义；语义修复等真实样本，并且要升 `PARSER_REV`。
4. **会话游标**。`jscompat` 自己实现 base64，只接受解出来是非负十进制整数的游标。`Number()` 才接受的写法（十六进制、科学计数、前后空白）按无效处理，从头开始。游标只来自 `next_cursor`，不影响正常翻页。
5. **`health`**。没有 HTTP 服务，因此去掉 `port`，版本号取 Rust crate 的版本，字段是 `ok`、`version`、`data_dir`、`ledger_path`、`schema_version`。这一项不对拍。
6. **会话详情的粒度**。FFI 上 `granularity` 必填，只接受 `hour` 或 `day`，不设默认值。
7. **Codex 不可靠响应 ID**。Rust 身份规则自 `PARSER_REV=5` 起，E4a 计时独立使用 `TIMING_REV=1`，Node 回滚路径仍为 4，分别写独立账本。可靠 id 的 key 字节不变；只按 id 形状判定，去掉开头 `resp_` 后为空、全 ASCII 数字或少于 16 字符的 id 不可靠，判定不依赖文件内容，部分历史副本也保持相同身份。Rust 用 `codex|<session>|<用量行 thread_id>|<原始时间戳>`，同一新键按文件内有效用量行顺序加 `#2`、`#3`，不使用 token 数；缺 thread/time 时回退规范化路径 hash＋物理行号。每条新身份的 `replaces` 均含旧响应键，首条停用旧 active 行，其余独立新增；`superseded_by` 指向首条承接记录，不表示完整的一对多关系。无响应 id 保持原位置回退。正常 id 的只读样本后缀长 35、48 或 50，16 字符阈值低于样本下限。Node golden 不重写；Rust 对拍只为明确的合成短 id `r1`、`response-local` 调整期望身份和 Codex revision，其余字段仍严格比较。回归覆盖独立子线程、完整与部分 Copied 历史、同时间序号、重复采集、追加、一对多重采集和压缩替换。真实账本执行仍需备份、副本演练及用户确认；Node 旧解析器不能用来重新采集 Rust revision 5 及以后采集的账本。

   已知限制：上游复用正常形状的长 id 时仍按旧 key 合并、原地更新，与 E1 之前的行为相同；不能据此保全复用长 id 的独立请求总数。2026-11-16 只读核查同事证据和本机日志，同一 session 与正常形状 id 对应不同原始时间戳或 usage 的情况均为 0，跨文件核查也包括在内。

   - 同一 thread、同一原始时间戳有多条不可靠请求时，日志前面的行被裁剪会使 `#n` 前移，可能覆盖旧行，造成多算。2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。
   - 同一文件里完全重复的用量行会得到 `#2`，造成多算。2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。
   - 不可靠 id 缺 `thread_id` 或原始时间戳不是字符串时，退回路径 hash 加行号，跨文件副本无法去重。2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。

8. **请求数与会话时段归属**。桌面查询追加 `request_count`，只数 active event，纯 cumulative 分组返回 NULL。会话列表的顶层用量与请求数属于所选时段，按 `scope()` 的 `observed_at` 归属；`cumulative` 是整个会话的汇总，起止时间与 `has_cumulative` 也取整个会话。有时段按时段 gross 降序，无时段按最近活动降序。快照算在开始那天，不做按天摊分。golden 只追加这些字段，保留旧字段的值。

分组、时间桶和会话另带 `event_gross_tokens`：只加 event 的四类 token，各列先 coalesce 再相加。“平均每次”使用此值除以 `request_count`，合并模型/工具时同时合并这两个字段，快照不进入分子。会话详情的 `period` 沿用列表的时段、工具和项目筛选，`session` 的累计不受筛选影响。累计查询先分页会话身份，再用 `idx_usage_session(source, session_id)` 取对应 active 记录；无时段而带项目/模型筛选时，排序仍以整个会话的最后活动为准。开始日期 chip 使用查询快照的固定偏移，非今年的日期包含年份；首页累计与时段 gross 不同时显示累计行。

9. **E4a 桌面请求计时**。桌面 schema v6 比 Node v5 仅多 usage_timings；迁移对拍继续严格比较全部 v5 表与列，另外测试 v6 表、备份与 WAL 行数。Node goldens 不重写，适配器对拍移除已断言无首字/生成证据的附加 timing 字段（既有 Pi 夹具的整次耗时另由 E4b 测试验证）；查询对拍仅移除已断言 NULL 指标和分母正确的 timing/model_timing，其他字段仍比较。计时独立使用按 source 区分的 TIMING_REV，claude 为 2，codex、kimi、zcode、qwen、pi、openhands、anythingllm、opencode、mimo、kilo、grok 为 1；用量 PARSER_REV 保持基线 codex=5、kimi=5、zcode=1；Node codex 仍为 4，身份差异继续遵循本节第 7 条。原有分组之和、用量和金额对拍测试保留。

D4 切换以后才考虑的修复（D3 不做）：时间桶按历史日期分别处理 DST；`pricing_snapshot` 只存 `{version}`、不能按旧版本重新估值（`write.js:481–485`）；会话详情默认粒度三处不一致（`read.js:587`、`api/v1/sessions.js:47`、`api/router.js:33`）；`ended_at` 不是 NULL 又解析不了时，这条 `cumulative` 记录既不进时间桶也不进 `unallocated`（`read.js:46–49`）。最后这一条 Rust 原样复现，并由独立的 golden 场景固定；适配器写入的 `ended_at` 只会是 ISO 时间或 NULL，现有数据碰不到。

## Rust 布局

### E4：请求与回合计时（桌面 schema v6）

D3 的 Node 对拍基线仍为 v5。桌面版增加独立的 `usage_timings`，不改 `usage_records` 的列、身份、`content_hash` 或计价。它以 `record_key` 为主键和外键，与 event 一对一；保存 source、首字、生成时长与整次调用耗时 duration_ms（整数毫秒）、各自的 method（含 duration_method）、`timing_output_tokens`、scope、status、source_file、计时版本和独立的 timing_hash；v6 的 usage_timings.parser_rev 列保留原名，但只存 TIMING_REV，与 usage_records.parser_rev 无关。计时有自己的按 source 区分的 revision：claude 为 2，codex、kimi、zcode、qwen、pi、openhands、anythingllm、opencode、mimo、kilo、grok 为 1；值、身份或时间改变要升 PARSER_REV 的契约仅适用于用量记录，计时修正规则只升 TIMING_REV，不改用量版本、内容或价格。

- **≈首字时间**（界面名“首字（开始回复前要等）”）：发出请求至首次实际输出的等待，思考、工具参数、正文都算；元数据和 role-only 分块不算。Kimi Code、ZCode、Codex 使用 `request`；OpenCode、MiMo、Kilo 另支持推理开始事件代理，Grok 使用独立的 `turn`。Codex 仅能观察思考与回复项，工具专用输出没有首字样本。
- **≈速度**（界面名“速度（回复时每秒出多少）”）：该请求的输出 token（adapter 现有口径，含推理）除以首次输出至流结束的秒数。分子独立存成 `timing_output_tokens`；只有 `status=completed`、输出已知且生成时长大于 0 的请求进入速度统计。不设 token 门槛。
- **≈请求平均吞吐**（界面名“平均速度（算上等待）”）：1000 × Σtiming_output_tokens ÷ Σduration_ms，包含首字前的等待，与“≈速度”分开。只计 status=completed、输出已知、duration_ms>0 的样本，按 duration_method 分组，不平均逐条吞吐。duration_ms 与其他时长一起存储、hash、保留或整组替换；新接入来源差值≤0、字段无效或无法唯一配对时为 NULL。scope 只允许 request/turn，method 增加 content_event_proxy；v6 未发布，直接扩展 timings.sql，不新增 schema 版本。
- 首字按 method 分组，使用 nearest-rank：升序排列 n 个样本，分位数 p 取第 `ceil(p*n)` 个（从 1 起）；中位数 p=0.5，p90 p=0.9，偶数样本取两个中间值里较小的一个。
- 速度按 generation_method 分组，取 `1000 * Σtiming_output_tokens / Σgeneration_ms`，不平均逐条速度。不同 method 不混合。
- 三项各自返回有效样本数 n；请求级 N 是同一筛选范围内 active event 的去重请求数，包括没有计时、失败和未知状态的请求，不包括 cumulative 或 Grok 回合。Grok 的 active event 一条代表一回合，单独返回 turn.turn_count，包括无计时回合；turn 计时不进入请求的分位数、速度、吞吐或覆盖率。通用用量查询的 request_count 沿用原口径，仅计时汇总分母按 scope 拆分。每个 method 的覆盖率都是自己的 n/N。没有样本时对应 ttft、speed 或 throughput 返回 NULL，界面省略该指标并列出缺失项；N=0 不计算百分比。
- `client_reported` 表示客户端记录的计时（Kimi、ZCode），`log_timestamps` 表示按日志时间戳估算（Codex）。content_event_proxy 表示“按推理开始事件估算”。首字、生成时长、整次调用耗时分别带 method；缺值的 method 也为 NULL。客户端计时仍受网络、代理、分块与缓冲影响。
- status：`completed` 为请求窗口正常结束（含工具调用结束、达到输出上限）；`partial` 为有用量但仍在运行；`failed` 为已记录失败；`cancelled` 为已记录取消；`unknown` 为无法确定结束状态。后三类与 partial 不进入速度统计；已有合法首字仍可计入首字分布。Kimi 读取 finishReason，ZCode 读取 model_usage.status（error 映射 failed、running 映射 partial）；Codex 的 token_usage_record 是每次响应终结的用量记录，记 completed，中止边界清空尚未配对的计时。

查询通过 usage_records join 计时，继承 active、时段、工具、项目、模型与会话筛选。会话详情的 timing 使用 period 筛选；明细 source/model/source_model 分组保持同一过滤口径。breakdown 和 session_detail 各在一个读取事务里计算用量与计时。`source_model` 另外返回每个模型在当前筛选下的 `model_timing`，供界面合并工具分组时使用，不能由各工具的中位数推导模型中位数。首页不展示计时。

工具/模型明细把计时放在对应主行下方的可换行指标区，左侧标“每次请求”；至少一项有样本才显示请求计时行。turn_count > 0 时另加同样样式的“每轮对话”行。主行与计时行共用点击、悬停和卡片内的墨水边界，宽屏分隔线在整个行组下方。宽屏表格沿用 860 最小宽度，不增加计时列；工具/模型表格可用宽度不足 860 时使用窄屏行布局，不横向滚动。不显示计时的维度保持原布局。模型行的工具图标最多显示 3 个，多出的用“+N”标记，悬停列出全部工具名；模型名保留可见宽度，单行省略并提供全名悬停提示，窄屏同样处理。会话详情使用标题为“每次请求”“每轮对话”的独立卡片；Grok 即使当前时段没有样本也保留回合卡片，纯回合会话不展示请求卡片。

计时区共用文案和缺失提示。首字显示“一般 x.xx 秒，慢时 y.yy 秒”，只有一个样本或两分位数相同时仅显示“x.xx 秒”；速度和平均速度显示“约 x.x token/s”。只有 0 < n < N 时显示“N 次里 n 次有记录”，n=N 时省略，N 与 n 沿用请求列的千位分隔格式。无样本的指标不显示，在计时区末尾列出“日志里没记：首字、速度、平均速度”中的缺失项。首字的小“?”说明为“从发出请求到看到第一段输出（含思考）的时间。‘一般’是一半请求不超过这个时间，‘慢时’是九成请求不超过这个时间。”其余指标的小“?”说明输出速度和包含等待的平均速度；行标签说明日志推算的约值及整轮对话与每次请求不能直接比较。多个 method 仍独立展示，并保留来源小字。

跨文件副本先按现有 settle 规则选定 usage 的归属，计时随同被保留的记录写入；不能用副本的计时补齐原件。计时按整组保留或替换，不逐指标拼接：本次用量新增或 content_hash 改变并原地更新时，计时整组换成本次解析结果，缺少 timing 对象则删除旧计时，不能沿用与当前用量不匹配的窗口和输出分子；只有本次用量 content_hash 与原来相同，才适用以下保留规则：source_file 和 TIMING_REV 都相同时，旧组 status=completed 就整组保留，不论新组是否缺值或为超集，避免日志裁剪缩短已完成窗口；只有旧组不是 completed，且新组为旧计时已知指标的超集（旧的每个非 NULL 时长（ttft_ms、generation_ms、duration_ms）在新值中也非 NULL）时，才整组替换，支持 ZCode 从 partial 增长到 completed；否则整组保留。status、timing_output_tokens、三个 method 和 scope 随整组决定，不从另一组补齐；选择后再计算 timing_hash，重复采集不反复更新。source_file 或 TIMING_REV 变化时整组替换，包括撤销，不能继承旧归属文件的计时；文件成功重解析后，新 TIMING_REV 不再产出的旧计时会清除，即使空产出保护仍保留历史用量。文件没有被发现或读取失败不清除计时。每次 sync 都重新发现并读取全部日志，无 mtime/hash 跳过缓存，因此 TIMING_REV 改变无需额外重读触发；只清除旧计时，不停用用量，用量因自身版本升级或 replaces 停用时仍删除其计时。

**v6 迁移与回退**：先沿用原流程把 v1–v4 升到 v5；已有磁盘账本在升 v6 前用 `VACUUM INTO` 生成一致的 v5 备份，包含已提交 WAL 内容，不能直接复制在线主文件。文件名为 `ledger-v5-YYYY-MM-DD-<毫秒时间>-<序号>.db`，位于账本所在数据目录，已有文件不覆盖；备份失败不创建 v6 表。新建空账本和内存测试库不需要旧库备份。随后在事务里建表并设置 user_version=6。旧版桌面应用拒绝打开 v6；恢复 v5 备份的步骤见 app/README.md。Node 回退目录 `~/.token-lens` 不受影响。

统计代码放在 `app/rust/src/stats/`，和新闻代码互不依赖：

| 模块 | 职责 | 对应旧版 |
| --- | --- | --- |
| `jscompat` | JS 数字转字符串、`Date` 宽容解析、JSON 键序、`localeCompare`、`encodeURIComponent` | 散在各处 |
| `ledger/open` | 打开、PRAGMA、v1→v6 迁移、v5 一致备份、拒绝更高版本 | `db/open.js` |
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
| `session_detail_in_period` | 桌面扩展 | 会话详情的时段汇总；`period` 使用同一 `StatsFilter`，`session` 与 day timeline 保留整个会话 |
| `sources` | `/sources` | 总览、来源、会话 |
| `discovery` | `/discovery` | 引导 |
| `pricing` | `/pricing` | 总览、设置 |
| `health` | `/health` | 设置 |
| `sync` | `POST /sync` | 引导、来源、定时采集 |

- 金额在 FFI 上用整数 micro-USD 传递，界面显示用的六位小数字符串和低精度最大余数分配由 Rust `pricing` 统一给出。账本金额只用 Rust 的值，Dart 不重新计价；旧前端自己做的展示推导（按工具合计、比例、环比、币种换算、“缓存帮你省了”的估算）照旧版在 Dart 里做。
- 时区：Dart 传当前的 UTC 偏移分钟数，Rust 用它切所有历史，和旧版一致。快照里的时区名先读 `TZ`，没有再调用系统自带的 ICU（Windows `icu.dll`、macOS `libicucore`），不打包 ICU；macOS 上的链接和运行还没验证。
- 不迁移：`/usage/unallocated`（看板没用，`timeseries` 已含）、`POST /pricing/refresh`（旧版就是 501）、HTTP 边界（gate、token、port）及其响应缓存、CLI、只有测试在用的 `modelStatus` 和 `priceVersions`。
- 并发：同一时间只有一个采集在跑；查询可以和采集并发，读的是已提交的数据。

## 对拍

- 生成器 `scripts/parity/` 调用旧版的生产入口（`adapters[source]`、`payloadHash`、`fileTag`、`Ledger`、`read`、各个 service），固定 `now`、时区和路径字符串，输出 UTF-8 JSONL。每行的 `type` 是 `adapter_record`、`identity`、`batch`、`ledger_row`、`price`、`query`、`run` 之一，字段顺序固定，NULL 显式写出。
- 夹具：现有的真实裁剪样本（codex、qwen、pi），加上把各测试里内联构造的合成输入整理成的静态文件，放在 `test/fixtures/`。
- 旧版输出提交到 `app/rust/tests/golden/`。Rust 测试读同一批夹具，输出同样的 JSONL 并逐行比较；身份和金额按字节比较，没有确定顺序的查询先按身份排序再比较结构。
- 时钟：旧版直接读 `Date` 和 SQLite `unixepoch()`，没有注入点。生成器用 Node 内置 `node:test` 的 `mock.timers` 只冻结 `Date`（固定 `2026-01-15T12:00:00.000Z`；主时区 `Asia/Shanghai`，另有 UTC，Date 兼容表还含 `America/New_York`），这是生成器里唯一允许的替换，不改 `src/core`。Rust 凡是读当前时间的地方都经可注入的时钟。
- 只有四个字段写成 `"<volatile>"` 不比较：`usage_records.ingested_at`、`legacy_records.imported_at`、`pricing_snapshot.created_at`（SQLite 默认值）和 `runIngestion` 的 `durationMs`。`snapshot.generated_at`、`ingest_runs.started_at` / `finished_at`、滚动 7/30 日、`pricing_snapshot.verified_at` 由冻结的时刻决定，严格比较。
- 旧版改了行为就重新生成 golden，提交里要说明原因。

### D3.5 真实日志对拍与资源占用（已完成）

- 工具：`scripts/parity/real-logs-old.mjs`、`app/rust/examples/real_logs.rs`、`scripts/parity/compare-real.mjs`。用法见提交 `4baec9d` 的说明和各文件头。`StatsClient::new_with_fixed_clock` 只给工具用，不进入 Dart 绑定（`fc8bf22`）。报告放在仓库外，不提交。
- 对拍：新旧两版只读本机客户端日志的同一份快照，各写一个临时账本。账本行逐字段一致，只排除上面规定的四个易变字段；各项查询在全部、本月、本周、今天四个范围下一致。两版第二遍采集都不新增也不改动任何行。
- 覆盖：本机有日志的来源全部覆盖；本机没有日志的来源只由合成夹具和 golden 覆盖。所有来源的 `bad_fields`、`bad_times` 都是 0，「允许的差异」所列的异常形状未在本机真实日志中出现。
- 测量：同一份快照，新旧桌面程序各测一次空账本启动和一次已有账本启动。采集耗时持平；采集时新版峰值工作集约为旧版的一半，旧版计入 Node 和 WebView2 子进程，新版为单进程。
- 空闲：采集完成后，新版工作集更低，但私有内存与旧版相当，采集后没有回落。窗口出现时间不作比较：旧版先显示外壳窗口，新版在首帧后才显示，口径不同。

## 子阶段

每个子阶段做完都停下来评审。新的 Rust 依赖开工前列出名称、用途和缓存位置，经批准再装（预计有 rusqlite bundled、sha2、zstd、文件匹配，`localeCompare` 是否需要 ICU 排序库由 D3.1 评估）。

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| D3.1 | `jscompat`、账本打开/迁移/写入、计价、锁、`ingest`，claude 和 codex（含 zstd 多帧）的发现与适配器，`summary` 和 `breakdown`，一个最简的 Flutter 总览页 | 生成器和 golden 就位；两个来源的适配器、身份、账本行、计价、两个查询全部和 golden 一致；在旧版 v1–v4 账本的合成副本上迁移，结果与旧版一致；Rust/Flutter 全部检查通过 |
| D3.2a | 第二批 14 个：qwen、dsh、grok、aider、pi、cline、gemini、openhands、continue、trae、openclaw、kimi、codebuddy、commandcode | 每个来源都有静态夹具和 golden，逐条一致 |
| D3.2b | 第三批 11 个：hermes、cursor、opencode、kilo、goose、zed、copilot、mimo、minimax、zcode、anythingllm | 同上；SQLite 夹具包括 WAL 状态和打开失败两种情形 |
| D3.3 | 其余查询：时间桶、`unallocated`、分组矩阵、会话、来源检查、价格标记、`legacy_records` 计数、`lastRun` | 查询 golden 一致；分组之和等于总计；`ended_at` 为 NULL 或可解析时，各时间桶加 `unallocated` 等于总计 |
| D3.4 | 完整统计界面：总览、明细筛选、会话、来源、设置与价格、引导 | 和旧看板逐页截图对照；Flutter 测试覆盖筛选、空态、未知值、未定价 |
| D3.5 | 真实日志对拍和资源占用测量（已完成） | 同一快照的临时账本逐字段一致（排除规定的四个易变字段），四个范围的查询一致，重复采集无新增或改动；异常计数为 0，覆盖边界和同快照资源测量结论见「对拍」 |

D4（2026-11-12 完成）：真实账本先备份；新旧两版各拿一份副本，采集同一份日志快照，两边账本逐字段一致（易变字段同上），第二遍采集不新增也不改动；副本里原有的每条记录在新版采集后都还在，没有被停用，`content_hash` 不变。之后经用户确认，新版在自己的数据目录里接手一份副本；旧库原样保留，供旧版回退。对拍工具的 `--seed` 参数让两侧从同一份账本副本起步。
