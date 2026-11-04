# 阶段 L · 账本可信：实施规格

本文件是 [roadmap.md](roadmap.md) 阶段 L 的展开：每个小阶段要改什么、为什么、怎么验收。接手的人读完本文与 [adapters.md](adapters.md)、[log-schemas.yaml](log-schemas.yaml) 即可开工，不需要先前的会话记录。

行号是 2026-10-21（`64368fa` 之后）的位置，代码变了以函数名为准。

## 工作纪律

- 按 L1 → L6 顺序做，每个小阶段做完停下汇报，得到放行再进下一个。L2 可以和 L1 并行，W 阶段依赖 L2。
- 测试一律用临时 HOME、临时数据目录或 `:memory:`。开发中的命令都带 `--data-dir`，不碰 `~/.token-lens`。
- **真实账本 `~/.token-lens/ledger.db` 是持久数据**，里面大部分行的原始日志已删、无法重采（[adapters.md](adapters.md) 第六节）。任何会改它的步骤（schema 迁移、口径变更后的首次采集）都要：
  1. 备份到仓库外，文件名带日期与缘由（如 `ledger.db.<YYYYMMDD>.before-v4.bak`）；
  2. 在副本上迁移并全量采集，逐来源对比前后的四类 token 与金额，差异逐项给出原因；
  3. 用户确认后才动真实库。
- 对账报告含原始日志摘录（可能有提示词片段），写到仓库外，不进仓库。
- 真实日志不进仓库；回归用例用合成数据，形状照真实日志。
- 只修代码里能证实的错。字段语义上的推测（某客户端的 `prompt_tokens` 是否含缓存等）没有真实样本前只在 [adapters.md](adapters.md) 登记，不改代码。

## 起因：2026-10-21 只读审计的发现

确定性错误（看代码即可证实）：

| 问题 | 位置 | 后果 |
|---|---|---|
| 账本无法纠错 | `src/core/db/write.js`：没有任何地方把 `active` 置 0，`superseded_by` 无人写；累计值下降一律拒绝（`ingestBatch` 的 `cumulative_decrease` 分支） | 修好一个多算的适配器，账本也降不下来；改 record_key 规则后新旧两行并存，重复计数 |
| `payloadHash` 覆盖面太窄 | `write.js` 的 `payloadHash`，只含 kind、model、四类 token | `observed_at`、`ended_at`、`session_id`、缓存写分档变了不会写回，分档永远补不上 |
| 发现随启动目录变化 | `src/core/discovery.js` 14 处 `resolve(process.cwd(), '..')`（aider、hermes、cursor、opencode、goose、zed、continue、trae、copilot、openclaw、mimo、kimi、minimax、codebuddy） | 在不同目录跑 `lens`，扫到的文件不同，总额不同；`*/sessions.db`、`*/threads.db` 之类会扫进无关文件 |
| `HOME` 模块加载时固定 | `discovery.js:5` | 测试无法隔离；`reconcile.mjs` 也只能读真实目录 |
| CLI 采集不加锁 | `src/core/cli.js` 的 collect 路径直接调 `runIngestion`，不经 `src/core/http/sync-lock.js` | 与 serve 的定时采集并发写同一账本 |
| dsh 多算输入 | `src/core/adapters/dsh.js:21` `totals.uncachedInputTokens \|\| totals.inputTokens` | 合法的 0 回落到含缓存的 `inputTokens`；可能是 A3 里 dsh 多出 0.4–2.0% 的原因之一（未证实） |
| dsh 默认模型 | `dsh.js:32` 缺模型时写 `deepseek-flash`，该名在价目里有价 | 猜出来的模型进了金额 |
| 位置键跨文件冲突 | `claude.js:183` `claude\|<session>\|#n`；`qwen.js:41` `#ordinal` | 计数器按文件，两个文件同 session（或空 session）时互相覆盖，丢数 |
| claude 模型缺失写成字符串 | `claude.js:124` `'unknown'` | 未知被当成一个模型名 |
| 未知写成 0 | 除 codex 外 21 个适配器的 `\|\| 0` / `?? 0` / `toInt`；硬编码 0 的缓存字段：`cursor.js:272`、`goose.js:125`、`continue.js:121`、`copilot.js:73-75,172`、`hermes.js:52,77` | 违反「未知不是零」；`read.js` 的 `*_unknown` 计数对这些来源无意义 |
| 坏行与失败静默 | `src/core/adapters/_lines.js:20-23` 坏行 `catch {}`；dsh、hermes、cursor、opencode、goose、zed、copilot 整体 `catch {}` | `ingest.js` 的 `read_failed` 对这些来源永不触发，G1.5（[features.md](features.md)）未兑现 |
| 非法时间落 1970 | `_lines.js` `normalizeTimestamp` 对空值与非法值返回 `new Date(0)` | 1970 年的记录被正常入账 |
| `ingest_runs` 记录不全 | `write.js` `recordRun` 的 `started_at` 等于 `finished_at`；`relabeled` / `retimed` / 累计下降不入计数 | 采集面板看不出发生了什么 |
| 缓存未扣减（与 adapters.md 约定矛盾） | `aider.js:29`、`zed.js:78-81`、`continue.js:29-38` | 输入里含缓存时缓存被算两遍 |
| copilot 两库都读 | `discovery.js` copilot 同时匹配 `session-store.db` 与 `data.db`，`copilot.js` 各自产出 | 两库覆盖同一会话时重复（是否重叠未证实） |
| openclaw 归档重复 | `openclaw.js:54` 键为 `ts\|ordinal` | 归档副本序号对不齐时重复计数 |
| 其余键冲突 | cursor 常量 id `composer-session` / `chat-session`（`cursor.js:258,303`）与 CSV 文件名键（`cursor.js:182`）；trae 同 session 合并（`trae.js:123-125`）；aider 用 `commit_hash`（`aider.js:70-72`）；codex 回退到 `turn_id`（`codex.js:90`）；opencode 回退键无序号（`opencode.js:134`） | 覆盖丢数或重复计数 |
| goose 余量记成输出 | `goose.js:103-104` `total - (input + output)` 加进 output | 若余量是缓存，按输出单价计价 |
| cursor 死分支 | `cursor.js:244,253` `model` 已有默认值，`if (!model)` 永不成立 | — |
| 界面声称已处理但无代码 | `src/core/api/v1/sources.js` `SOURCE_LIMITS`：claude「不会重复计数」、codex「data.db 只作一次性基线」、openclaw「已经去重」 | 来源页给出没有依据的保证 |

另外：`scripts/audit/reconcile.mjs` 用同一份适配器重放，只能证明入库无损，证明不了字段语义（脚本自己在报告里写明了）。现有真实样本夹具只有 codex、qwen、pi（`test/fixtures/`），claude 虽是 A 级却只有合成用例。

---

## L1 账本能纠错（schema v4）

改动集中在 `src/core/db/open.js`（`SCHEMA_VERSION` 3 → 4，`migrate` 加分支）、`src/core/db/write.js`、`src/core/db/read.js`、`src/core/ingest.js`、`src/core/adapters/index.js`。`ledger.js` 只管理共享连接，读写分别经 `ledger.read` 与 `ledger.write` 调用。

1. `usage_records` 加列：
   - `source_file TEXT`：产出这一行的日志文件绝对路径。历史行为 NULL。
   - `parser_rev INTEGER`：产出时的适配器版本。历史行为 NULL。
   每个适配器导出一个版本常量（集中登记在 `adapters/index.js`），**改了某适配器的口径就把它加一**。
2. 停用：一个文件**完整解析成功**后，凡 `source_file` 等于它、本次没有再产出的活跃行，置 `active = 0`。文件读失败、解析中途抛错时不做这一步。`source_file` 为 NULL 或文件已不存在的行不动。
3. 键迁移：记录可带 `replaces: string[]`（旧 record_key）。入库时把旧行置 `active = 0`、`superseded_by = 新行 id`。专给 L3、L5 修键冲突用。
4. 累计值下降：
   - 旧行 `parser_rev` 与本次不同 → 允许覆盖，计入「口径修正」；
   - 相同 → 维持现状，按异常上报、保留旧值。
5. `payloadHash` 纳入 `observed_at`、`ended_at`、`session_id`、`cache_write_5m_tokens`、`cache_write_1h_tokens`。这会让下次采集时可重读的行各更新一次（`revision + 1`）；gross 与金额应不变，在副本上验证。
6. `ingest_runs`：`started_at` 取真实开始时间；按类计数写进 `notes` 的 JSON（或加列，二选一，在 `specs/api-v1.md` 写清），至少有：坏行、缺字段、零用量、读取失败、口径修正、停用、累计下降异常。来源页（B4 已接 `last_run`）照样能读。
7. 核对所有聚合查询只算 `active = 1`（`read.js` 现有 `WHERE active = 1` 的几处之外逐个查）。

实施记录（2026-10-24）：
- 第 2 条收紧为「只停用另一版解析器的产出」：同一版本下记录从文件里消失，计为 `vanished` 并上报，用量照常保留。客户端自己清理或改写日志也会让记录消失，按原规格会把真实用量删掉，与「日志删了照常计入」的立场冲突；口径修正都伴随 `parser_rev` 加一，靠版本差异就能停用旧产出。一条都没产出的文件不做停用，因为分不清空文件与适配器吞掉的读取失败。
- 文件级原子性：一个文件完整解析后才在一个事务里入库，解析中途抛错的文件一条都不写，取代原先按 2000 条分批提交、失败时丢半批的做法。
- 第 6 条采用加列：`ingest_runs.counts`（JSON 对象），`notes` 仍是异常字符串数组。运行开始时先登记 `running`，失败标 `failed`，未收尾的在下一次运行时标 `abandoned`。
- 版本未登记的历史行按第 1 版处理；批次 1 改过口径的 qwen、dsh、aider、pi 为第 2 版。
- 内容指纹纳入最后活动时间后，回填 `ended_at` 走更新路径，原「只补时间」的分支随之删除。

验收：
- 迁移：v3 库升到 v4，行数、四类 token、金额不变，新列为 NULL。
- 停用：文件里删掉一条记录再采集，对应行变 inactive，总额减少相应值；文件读失败时不停用任何行。
- `replaces`：新旧键不重复计数，`superseded_by` 指向新行。
- 口径修正：`parser_rev` 变化后累计值下降被接受，未变时仍报异常。
- [features.md](features.md) G2.1、G2.2：分组之和等于总额（沿用 `test/core/query.test.js`）。
- 真实账本按「工作纪律」走副本流程，报告给用户后再迁。

## L2 发现与运行时确定性

1. 删除 `discovery.js` 全部 `resolve(process.cwd(), '..')` 扫描。需要额外目录时用显式配置：`<data-dir>/sources.json`（每个来源可追加根目录）或 CLI 参数，二选一并写进 README。
2. 收窄 glob：
   - trae 不再读 app-data 下的全部 `*.json`，只读确认含用量的文件形状；
   - mimo、kimi、minimax、codebuddy 的 app-data 通配同理；
   - pi 现为 `**/*.jsonl`，[log-schemas.yaml](log-schemas.yaml) 写的是 `*/*.jsonl`，以本机实测为准统一。
3. `HOME` 改为每次调用 `discoverAll()` 时读取（`os.homedir()`），不在模块顶层固定。
4. CLI `collect` 走 `sync-lock.js` 的跨进程锁；拿不到锁时报出持有者 pid 并以非零码退出。
5. 测试：在两个不同 cwd 下 discovery 结果相同；锁被占用时第二个 collect 失败。

## L3 五个真实来源逐条对账

范围：claude、codex、qwen、dsh、pi（用户本机有真实日志）。

1. **独立 oracle**：`scripts/audit/oracle/<source>.mjs`，只按 [log-schemas.yaml](log-schemas.yaml) 从头写，**不 import 任何 `src/core/adapters` 代码**，按会话输出四类 token 合计。`scripts/audit/oracle-compare.mjs` 把 oracle 结果与账本（或临时库）按会话对比，输出差异表。两套独立实现对得上才算证据。
2. **客户端自报数**：codex 每个会话末尾的 `total_token_usage` 与逐条 `last_token_usage` 之和对比；dsh 的会话 `totals` 是客户端自报值，直接作为 oracle 基准。
3. **已知要修的**：
   - dsh：`dsh.js:21` 改为按字段是否存在取值（`??`），默认模型改 NULL；
   - claude、qwen：无 id 记录的键改为文件内稳定身份（文件路径 hash + 行内位置，或可用的 uuid），配 `replaces` 迁移旧键；claude 缺模型存 NULL；
   - claude 的 `message.id` 去重只在单文件内（`claude.js` `messageBucket`）。用 oracle 实测 resume/fork 是否把同一 `message.id` 复制进别的文件，有的话去重键不含 session。
4. **A3 定位**：
   - pi 与另一种计算方式有差异，尚未定位。按文件与 30 分钟桶核查，缩到具体条目。怀疑方向（未证实）：fork / branch 会话复制了带原 id 的条目而键含新 session；glob 深度。
   - dsh 与另一种计算方式有差异，尚未定位；先核查第 3 条修正后的逐条结果，再判断历史差异是否消除。
5. 每个确认的 bug 配一条合成回归用例，放 `test/core/<source>.test.js`。
6. 每个修改过的适配器 `parser_rev` 加一。

运行 reconcile / oracle 的安全方式：
- 先 `unset DB_PATH`（与 `--data-dir` 冲突会直接报错，见 `src/core/paths.js`）；
- 用 `runIngestion({ dataDir: '<临时目录>' })`（`src/core/ingest.js`）在临时目录建库，只写该目录；
- `node scripts/audit/reconcile.mjs --data-dir <临时目录> --out <仓库外的报告路径> --source claude,codex,qwen,dsh,pi`；
- L2 之前 discovery 还受 cwd 影响，在父目录没有杂项的目录下运行。

验收：五个来源 oracle 与账本按会话零差异；有差异的逐条能说出原因，写进 [adapters.md](adapters.md) 第六节，并更新该节的对账表。

实施记录（2026-10-24，身份键部分）：
- 实测确认分支或续接会把带原 `message.id` 的消息复制进新会话的文件，复制的行连 `uuid` 也保留。claude 的键改为 `claude|<message.id>`；没有 id 时用 `claude|<uuid>`，再没有才用 `claude|f<路径 sha256 前 12 位>:<行号>`。每条都用 `replaces` 指向第 1 版的会话内键。缺模型存 NULL。`parser_rev` 为 2。
- 跨文件取舍放在 `ingest.js` 的 `settleCopies`：同一来源的文件先全部解析，同一条事件记录出现在多个文件里时，由开始最早的文件写入（文件内最早的 `observed_at`，相同时按路径），会话因此是原始会话；其余副本计 `cross_file_copies`，它们的键和 `replaces` 交给 `ingestBatch` 的 `elsewhere`，不会被当作从所在文件消失。原始会话的日志删掉后，副本接手计数。累计快照不参与，跨文件的旧快照不一定是对的。
- qwen、pi 没有 id 的记录改为 `<source>|<session>|f<路径 hash>:<行号>`，`replaces` 指向旧的 `#n` 键；同一会话分在两个文件里时不再撞成一行。两者 `parser_rev` 为 3。行号来自 `_lines.js` 的 `numberedJsonLines`，按物理行计，空行与坏行也算。
- 日志已删的历史重复行采集修不到，由仓库外的一次性脚本按「末段 id、`observed_at`、四类 token 都相同」停用，`superseded_by` 指向保留行；保留行优先新键，其次仍有 `source_file` 的行，再次 id 最小的行。

## L4 未知不是零、失败可见

1. 新建 `src/core/adapters/_num.js`：字段不存在 → `null`，存在且可解析 → 整数，存在但非法 → 计为坏字段。22 个适配器统一改用它，替换散落的 `|| 0`、`?? 0`、`toInt`。硬编码 0 的缓存字段改 NULL。
2. `_lines.js` 坏行计数并向上交给 ingest；各适配器的整体 `catch {}` 改为上报（计数或抛出），最终进 `ingest_runs`。
3. 时间戳缺失或非法：整条按坏记录计数，不入账。`normalizeTimestamp` 不再返回 1970。
4. 「零用量记录」继续不入账，但要计数。

验收：在账本副本上采集，gross 与金额逐来源不变（NULL 与 0 在合计里等价），只有 `revision` 变化；新增用例覆盖缺字段、坏行、非法时间各一条。

实施记录（2026-10-24）：
- 22 个适配器统一经 `_num.js` 取非负整数；字段缺失为 NULL，非法字段计 `bad_fields`，四类均为 0 或未知时计 `zero_usage` 并不入账。缓存字段不再硬编码为 0；合计与推理字段仍保留各来源原有口径。
- `numberedJsonLines` / `jsonLines` 接收每文件的解析计数；主 JSON 与数据库读取错误抛给 `runIngestion` 计 `read_failed`，行内或附属 JSON 错误计 `bad_lines`。数据库表探测也不再吞掉 SQLite 错误。
- 时间缺失或非法时 `normalizeTimestamp` 返回 NULL，`runIngestion` 丢弃该记录并计 `bad_times`；文件完整解析成功后才合并计数。
- 全部适配器的 `PARSER_REV` 已加一。隔离核心测试覆盖缺失与非法字段、合法 0、坏行、零用量、非法时间和损坏数据库。
- 真实账本只读快照的副本对账通过：既有记录逐来源四类 token、gross 与金额不变；qwen 行仅发生 `cache_write_tokens: 0 → NULL` 和 `revision + 1`，无停用或异常。第二轮全部 unchanged，完整性检查通过。详细证据在仓库外归档；真实账本采集仍待用户确认。

## L5 B 级适配器的确定性错误

只修上表里能从代码证实的项：

- aider、zed、continue：输入为含缓存总数时扣减缓存，与 [adapters.md](adapters.md) 第三节契约表一致；
- copilot：同一会话只取一份来源；`SOURCE_LIMITS` 里「data.db 只作一次性基线」要么实现、要么删除；
- openclaw：键改为内容身份，归档与活跃副本只计一次；`SOURCE_LIMITS`「已经去重」以实现为准改写；
- 键冲突：cursor 常量 id 与 CSV 文件名键、trae 同 session 合并、aider `commit_hash`、codex `turn_id` 回退、opencode 回退键，统一配 `replaces`；
- goose：`total - (input + output)` 的余量不再并入 output，单独记录为未知或 NULL，并在 adapters.md 说明；
- cursor：删掉永不成立的 `if (!model)` 分支，缺模型存 NULL。

只登记、不改代码（等真实样本）：mimo / kimi / minimax / codebuddy 的 `prompt_tokens` 是否含缓存；gemini 的 thinking token 是否应并入输出；zed `request_token_usage` 是逐请求还是逐轮最新值；gemini、trae、openclaw、mimo 家族用 `row.id` 当会话 id 是否成立；cline、continue、cursor 数据库路径是否读到了真实客户端写的位置。

每处修复一条回归用例，对应适配器 `parser_rev` 加一。

实施记录（2026-10-26，L5 与 L2 第 2 条）：
- Aider 按输入口径扣缓存读取：OpenAI `prompt_tokens` 不再依赖缓存字段的拼写，Anthropic `input_tokens` 保持分列。缓存写入是否包含在 prompt 中未明确，不猜扣减。Zed、Continue 的事实规格只列字段，未明确各字段包含缓存读还是读写，与契约表的笼统说法不足以确定扣减量；本批只登记，保持代码和版本不变。
- Copilot 保留两库发现，在适配层按会话优先有效明细，`data.db` 仅补充无明细的会话；明细的 `replaces` 停用旧汇总。汇总不是一次性基线。OpenClaw 用不含用量的内容身份识别归档与活跃副本，配合既有 `settleCopies` 合并旧键；两条 `SOURCE_LIMITS` 与实现一致。
- 修复 Cursor 常量回退与同名 CSV、Trae 同 session 多条 JSON、Aider 复用 commit、Codex 复用 turn、OpenCode 同时间无 id 的键冲突。保留已有明确 id；回退采用文件 hash 与行号/条目位置，每个新键均带 `replaces`。Trae 的累计判定保持原有语义。Cursor 删去不可达的消息模型回退，缺模型为 NULL。
- Codex 的位置键在计算路径 hash 前去掉末尾 `.zst`，同一 rollout 从 `.jsonl` 压缩替换为 `.jsonl.zst` 后保持原键。归一化仅限 Codex 调用处，公共 `fileTag` 与其他适配器不变；隔离 ingestion 回归验证活跃行数、四类 token 与 gross 不变，`source_file` 更新为压缩路径。
- Goose 只计明确 input/output，分类未知的 total 余量不入账，缓存仍为 NULL；只有 total 时不产出记录。
- L2 glob：Trae app-data 只查 `User/globalStorage/**/*trae*.{json,jsonl}`；mimo / kimi / minimax / codebuddy 的 app-data 只查工具根下 `sessions` / `logs`，CodeBuddy 的 `.config` 规则同步收窄；保留 Kimi Code wire 专用规则。Pi 只读统计本机目录：一层子目录 45 个 JSONL、三层 54 个，保留 `**/*.jsonl`，修正规格。
- `PARSER_REV`：aider 3→4；codex、cursor、opencode、goose、trae、copilot、openclaw 各 2→3，仅各加一次。仅收窄发现范围的适配器不改版本。
- 合成回归覆盖各项错误，修复前逐项失败，修复后通过；内存/临时账本覆盖旧键停用、重复采集与跨文件副本。未读写真实账本，未做真实日志语义验收。无 id 的位置键仍依赖文件路径及顺序；历史日志已删的旧行不能由本批修复。

实施记录（2026-10-26，缺模型存 NULL）：
- 逐个核查 22 个适配器。qwen、grok、aider、pi、hermes、cline、gemini、opencode、goose、zed、continue、trae、copilot、openclaw、mimo、minimax、codebuddy 共 17 个去掉固定模型回退；日志及其会话元数据没有模型时产出 NULL。claude、codex、dsh、cursor、kimi 已符合契约，不改口径或版本。
- 保留日志中已出现的真实模型：Pi 的 model_change、Cline 的 ui_messages 时间线、Grok 的 summary，以及各适配器已有的会话/消息模型优先级。Hermes 的缺模型记录仍用原有身份键占位，model 字段为 NULL，避免同一快照因键变化重复入账。
- `PARSER_REV`：qwen、aider、pi 各 4→5；grok、hermes、cline、gemini、zed、continue、mimo、minimax、codebuddy 各 2→3；opencode、goose、trae、copilot、openclaw 各 3→4，每个只加一次。
- 对应适配器测试覆盖缺模型的各条解析路径、Pi 的真实模型沿用和 Hermes 的身份保持；MiMo 内存账本回归覆盖重解析后清除猜测金额、用量与行数不变。测试先失败后通过。未读写真实账本；已有历史行只有在日志可重读并重新采集时才能纠正，日志已丢失的行不在本次范围。

## L6 合理性检查（界面可见）

1. 账本自检（`read.js` 新查询），结果并入 `/api/v1/sources`，来源页逐条显示：
   - 时间晚于当前或早于 2023-01-01；
   - 单条记录 gross 超过 1e8；
   - `cache_read` 远超同条输入的异常比例（阈值写进 adapters.md）；
   - 模型为 NULL；
   - 同一会话混用 event 与 cumulative（`reconcile.mjs` 已有同名检查，复用口径）。
2. 每个来源两个计数：可复核（`source_file` 仍存在）与日志已删、不可复核。后者照常计入总额，但界面明示。
3. `api/v1/sources.js` 的 `EVIDENCE` 与 `SOURCE_LIMITS` 按 L3–L5 的实际结果改写；没有代码支撑的「已处理」一律去掉。

验收：`test/core/sources-pricing.test.js` 补用例；`npm run dashboard:build` 与 `dashboard:typecheck` 通过；来源页能看到自检条目与两类计数。

实施记录（2026-10-26）：
- `read.js` 新增 `sourceChecks` 与 `sourceFiles`；`/api/v1/sources` 每个来源带 `checks` 与 `retention`，来源页显示「日志留存」与「自检」两行，自检只列出非零项。字段定义见 [api-v1.md](api-v1.md)。
- 「单条 gross 超过 1e8」只查逐条请求：累计快照是整场会话的总数，超过 1 亿是正常的，列进来只会把 dsh 这类来源长期标成异常。
- 「`cache_read` 远超同条输入」没有实现：四类 token 落库后互不重叠，claude 一次请求只有个位数的输入、几十万的缓存读取是常态，这个比例分不出错误与正常，定不出有意义的阈值。缓存被重复计入的问题由 L3 的 oracle 与客户端自报合计核对。
- 文件是否还在由服务层按文件判断，每个文件只查一次；`source_file` 为 NULL 的行计入日志已删。
- `SOURCE_LIMITS` 去掉没有代码支撑的说法：zed 的「imported 需跳过」代码里没有实现，改为「有影响」；zed、continue 的输入是否含缓存未确认、未扣减，补为「有影响」；goose 补上 total 余量不入账。证据等级的调整放在 N1。

## 每个小阶段都要跑

```sh
npm test
npm run dashboard:build      # 动到 dashboard 时
npm run dashboard:typecheck  # 动到 dashboard 时
```

结束时更新 [roadmap.md](roadmap.md) 阶段 L 表格的状态列与顶部状态行；口径有变的同步改 [adapters.md](adapters.md)、[log-schemas.yaml](log-schemas.yaml)、[api-v1.md](api-v1.md)。
