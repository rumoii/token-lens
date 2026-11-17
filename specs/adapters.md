# 适配器契约（27 组）

本文件回答一个适配器实现者必须知道、但日志格式本身不会告诉他的事：这条记录的**稳定身份**是什么、**时间是哪个时间**、**四类 token 谁包含谁**、**它是事件还是累计快照**、以及**哪里会错**。

字段位置的事实来源是 [log-schemas.yaml](log-schemas.yaml)。本文件不重复路径与字段名，只写契约。

---

## 一、通用契约

每个适配器导出 `parse<X>(filePath) → AsyncIterable<Record>`，yield 的字段固定：

```
record_key           稳定身份，不含任何 token 数
source               27 组之一
session_id           NULL 表示未知，不用空串冒充
project_key          NULL 除非有可靠项目元数据
model                NULL 表示未知
observed_at          UTC ISO8601
kind                 'event' | 'cumulative'
input_tokens         NULL 表示未知，不是 0
output_tokens
cache_read_tokens
cache_write_tokens
```

四类 token 落库后**互不重叠**：`gross = input + output + cache_read + cache_write`。

各客户端的原始口径不同，扣减责任在适配层，不在查询层：

| 原始口径 | 处理 |
|---|---|
| 输入已含缓存读取 | `input = input_raw - cache_read` |
| 输入已含缓存读写 | `input = input_raw - cache_read - cache_write` |
| 输出已含推理 | 原样保留 `output`，不另加推理 |
| 输出未含推理（客户端分开报） | `output = output_raw + reasoning_raw` |
| 只报累计总量 | `kind = 'cumulative'`，按会话覆盖，不累加；日志给出最后活动时间时一并填 `ended_at` |

## 二、稳定身份

身份决定「重复采集是否重复计数」。优先级从高到低：

1. 客户端给出的一次请求/响应/消息 ID → `<source>|<session>|<id>`
2. 会话级累计快照 → `<source>|<session>`，`kind='cumulative'`
3. 追加型日志且无 ID → `<source>|<session>|<observed_at>|<文件内序号>`

禁止把 token 数放进身份。一经发现按缺陷处理。

## 三、27 组契约表

证据等级：**A** = 用本机真实样本对照过；**B** = 仅合成样本验证；**C** = 未验证。本机现有真实样本的客户端见第四节。

| # | source | 身份（已实现） | 时间含义 | 包含关系 | 类型 | 已知限制 | 等级 |
|---|---|---|---|---|---|---|---|
| 1 | `claude` | `claude\|<session>\|<message.id>` | 该消息落盘时刻 | 输入不含缓存读写 | 事件 | 无 ID 的消息落到 `#<序号>` | **A** |
| 2 | `codex` | Rust rev 5：可靠 id 保持 `codex\|<session>\|<response_id>`；只按 id 形状判定，去掉开头 `resp_` 后为空、全 ASCII 数字或少于 16 字符时，改用 `codex\|<session>\|<用量行 thread_id>\|<原始时间戳>`，相同新键依文件内有效用量行顺序加 `#2`、`#3`；缺 thread/time 或无响应 id 用去掉末尾 `.zst` 的路径 hash+物理行号 | 该响应落盘时刻 | **cached ⊂ input** | 事件 | 正常形状长 id 被上游复用时仍按旧 key 合并、原地更新，与 E1 之前相同；同一 thread 同一原始时间戳有多条不可靠请求时，非前缀的部分历史副本可能使 `#n` 错位（P3 已知限制，完整历史前缀副本不受此问题影响）；同一 thread、同一原始时间戳有多条不可靠请求时，日志前面的行被裁剪会使 `#n` 前移，可能覆盖旧行，造成多算（2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0）；同一文件里完全重复的用量行会得到 `#2`，造成多算（2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0）；不可靠 id 缺 `thread_id` 或原始时间戳不是字符串时，退回路径 hash 加行号，跨文件副本无法去重（2026-11-16 用同事证据只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0）；新身份 `replaces` 旧响应键；复制历史沿用原行 thread/time 去重；`turn_id` 不当作响应 id；压缩替换不改变身份；只取 `usage`；Node rev 4 保持旧规则，见 [stats.md](stats.md#允许的差异) | **A** |
| 3 | `qwen` | `qwen\|<session>\|<条目 id>` | 事件时刻 | `inputTokens` 含缓存需扣；旧输入字段已分列 | 事件 | `thoughtsTokens` 是否另加随上游认证/字段口径而异，见下文；`id` 是条目身份，不是会话身份；缺模型存 NULL | **A** |
| 4 | `dsh` | `dsh\|<session>` | 会话创建时刻；`ended_at` 取 `timeContext.lastMessageTime` | 输入已是 `uncachedInputTokens` | **累计** | 全量覆写文件；生产与 oracle 的 session 均为文件 stem 剥除开头一个 `session-` | **A** |
| 5 | `grok` | `grok\|<session>\|<turn>`，无 turn 用时间+序号 | 回合完成时刻 | 输入/缓存分开报 | 事件 | 只有 `turn_completed` 带用量；本机无用量样本；缺模型存 NULL | B |
| 6 | `aider` | `aider\|<session>\|f<路径 hash>:<物理行号>` | 交互时刻 | OpenAI `prompt_tokens` 扣缓存读取；Anthropic `input_tokens` 已分列 | 事件 | `commit_hash` 不能标识一次调用；路径变化后的无 id 日志无法自动识别为副本；缺模型存 NULL | B |
| 7 | `pi` | `pi\|<session>\|<message.id>` | 消息时刻 | 四项分开报 | 事件 | 会话头与用量不在同一行；缺模型存 NULL | **A** |
| 8 | `hermes` | `hermes\|<session>\|<model>` | `last_seen` | 四项分开报 | **累计** | 两张表结构不同，优先细粒度表；缺模型存 NULL | B |
| 9 | `cline` | `cline\|<taskId>\|<消息 id>`，无则时间+序号 | `ts` | 读取的 `usage.*` 字段没有找到任何版本写入的依据 | 事件 | 当前 Cline（SDK）与 Roo Code 的用量格式尚未接入，见第三节；模型可能只在 `ui_messages.json` 里；缺模型存 NULL | B |
| 10 | `gemini` | 顶层汇总 `gemini\|<session>`；逐消息 `…\|<时间>\|<序号>` | `startTime`/`createTime` | 输入含缓存，需扣 | 累计 / 事件 | 目录下混有非用量 JSON；`$.id` 究竟是会话还是条目未确认；缺模型存 NULL | B |
| 11 | `cursor` | CSV 用文件 hash+日期+序号；composer/tab 用条目 id，无 id 用文件 hash+通道+位置 | 条目时间 | CSV 头部分列 | 事件 / 累计 | 缺模型为 NULL；SQLite 是内部结构，位置键不能跟随条目重排 | B |
| 12 | `opencode` | `opencode\|<session>\|<行 id>`；无 id 用文件 hash+时间+查询序号 | `time_updated` | 输出须并入 reasoning | 事件 | project_key 按 session_id 取 v1 session.directory / v2 session_v2.directory，经 projectFromCwd 规范化，无目录存 NULL；目录随会话移动，不还原历史目录；回退键依赖查询顺序；缺模型存 NULL；OPENCODE_DB 已设置时只发现指定普通文件，不回退默认或历史库；不扫描渠道库或 opencode-next.db，渠道库需显式指定，以免混入备份或迁移残留 | B |
| 13 | `goose` | `goose\|<session>` | `created_at` | 只计明确的累计 input/output | **累计** | `total - input - output` 分类未知，不入账；缓存为 NULL，只有 total 时不产出；缺模型存 NULL | B |
| 14 | `zed` | `zed\|<thread id>` | `updated_at` | 缓存包含关系未明确，保持原取值 | **累计** | 规格仅列字段，未说明 input 含缓存读还是读写；payload 可压缩，跳过 imported；缺模型存 NULL | B |
| 15 | `continue` | 逐轮 `…\|<轮 id>`；顶层汇总 `continue\|<session>` | `dateCreated` | 各输入候选字段的缓存包含关系待确认 | 事件 / 累计 | 规格未说明 `promptTokens`、`usage.prompt_tokens`、`tokenCount.input` 的包含关系，暂不扣减；缺模型存 NULL | B |
| 16 | `trae` | JSON 用文件 hash+条目位置；JSONL 保留 message_id 或时间+序号 | `usage_time` | 缓存取值保持既有口径 | 事件 / 累计 | 带 session_id 的 JSON 条目仍是累计；多个条目各有身份，重排无法跟随；row.id 语义待确认；缺模型存 NULL | B |
| 17 | `copilot` | 明细 `…\|<行 id>`（表无 `id` 列时用时间+序号）；会话表 `copilot\|<session>` | `created_at` | 输出须并入 reasoning | 事件 / 累计 | 同目录两库按会话优先有效明细；data.db 每次补充无明细会话，不是一次性基线；缺模型存 NULL | B |
| 18 | `openclaw` | `openclaw\|c<内容 sha256>`，不含用量、路径或会话 | 消息时刻 | 四项分开报 | 事件 | 相同内容身份的归档/活跃副本只计一次；时间、原始编号、角色、正文与工具调用都相同的事件无法区分；缺模型存 NULL | B |
| 19 | `mimo` | `mimo\|<session>\|<message.id>`；无 id 用文件 hash+时间+查询序号 | `time_updated`，缺失回退 `time_created` 或消息时间 | input 不含缓存；output 并入独立 reasoning | 事件 | 复用 OpenCode 解析；项目只取 session.directory；删会话级联删消息，已采集用量保留；默认只发现 mimocode.db，仅 MIMOCODE_DISABLE_CHANNEL_DB=false/0 时读 mimocode-*.db，同目录备份库可能与正式库共享消息 id，用量不同时可能采用较旧的一份；Desktop 路径来自第三方，未核实；缺模型存 NULL | B |
| 20 | `kimi` | `kimi\|<session>\|<条目 id>`，无则时间+序号；Kimi Code wire 用文件 hash+事件时间+物理行号 | 时间戳 | 四项分开报 | 事件 | 主 agent 与子 agent 都计入；turn 与会话压缩调用都计入；wire 只计 `usage.record`，`subagent.completed` 带的子 agent 汇总不另计；缺模型存 NULL | **A** |
| 21 | `minimax` | `minimax\|<session_id>\|<local_runtime_token_usage.id>` | 请求 `ts`（毫秒） | 四项分开报，output 已含 reasoning，不再叠加 | 事件 | 项目只取 local_runtime_sessions.workspace_dir；rewind 与删会话会删用量行，已采集用量保留；无 provider 字段存 NULL；缺模型存 NULL | B |
| 22 | `codebuddy` | CLI 用文件 hash+物理行号；桌面 `codebuddy\|<会话目录>\|<request.id>`，无 id 用文件 hash+数组位置 | CLI timestamp/ts；桌面 startedAt | input 含缓存读，扣 read；miss 为未缓存输入；write 单列 | 事件 | 第三方逆向依据；CLI 三个 projects 根与桌面请求索引；CLI 移动/重排无法延续位置键；项目只取明写 cwd；provider 无已验证字段存 NULL；缺模型存 NULL | B |
| 23 | `kilo` | `kilo\|<session_id>\|<session_message.id>` | 消息 `data.time.created`（创建时刻） | input 不含缓存；output 并入独立 reasoning | 事件 | project_key 按 session_id 取 session.directory，经 projectFromCwd 规范化，无目录存 NULL；目录随会话移动，不还原历史目录；只读新版 session_message，不叠加汇总或兼容投影；缺模型及 legacy 存 NULL；旧版 JSON 任务目录未接入；开发 channel 需 KILO_DB | B |
| 24 | `openhands` | `openhands\|<conversation>\|<usageId>\|<response_id>`；重复响应加 `#2`、`#3`，各段 URI 转义 | 本会话相同响应 ID 的最早事件时间；无时区值按采集机本地时区解释 | prompt 含缓存读写，均扣除；completion 已含 reasoning | 事件 | 只计本会话事件能关联的逐次用量；task、delegate、agent hook 从自己的会话记录读取，父副本不计；未关联的已知子会话条目计 subagent_copies，其余计 bad_times；缺模型、default、unknown 存 NULL；仅原生 CLI，SDK 自定义脚本、ACP、服务端／容器／远程 runtime 未接入 | B |
| 25 | `zcode` | `zcode\|<session_id>\|<model_usage.id>`；缺会话用 `-`，缺 id 跳过 | 请求 `started_at`（毫秒） | input 含缓存读写，均扣除；output 已含 reasoning | 事件 | 只读 model_usage，不叠加汇总；扣成负数记 bad_fields、input 存 NULL；失败/重试有用量照计；项目只取 session.directory；客户端保留 30 天，已采集的剪枝行仍计入；默认库与自定义或迁移后的库并存且请求 id 相同时，按副本规则只采一份，若在请求进行中复制库导致同一 id 的 token 不同，可能采到较旧的一份；上游 model_usage 行在请求完成时写定，正常使用中两份库对同一 id 的值一致；缺模型存 NULL | B |
| 26 | `commandcode` | `commandcode\|<header.id>\|<entry.id>` | entry.timestamp（落盘时刻） | input 含缓存读写，均扣；output 已含 reasoning | 事件 | npm 1.88.2 的 v3 transcript；只计 assistant message 的 entry.usage；不读 meta/checkpoints/prompts；项目只取 header.cwd；provider 无持久化字段存 NULL；历史 v1/v2 未接入 | B |
| 27 | `anythingllm` | `anythingllm\|<workspaceId>\|<chat.id>` | workspace_chats.createdAt，毫秒或 UTC SQL 时间 | prompt/completion 可能估算或 provider 返回；缓存两列 NULL | 事件 | 只读桌面 SQLite；include=false 仍计入；删 workspace 在应用层批量删 chats，账本保留已采集值；model/provider 只取 metrics 显式字段；项目 NULL | B |

B 档里 `grok`、`hermes`、`copilot` 在本机有数据目录，但没有可对照的用量（见第四节）；其余 18 组本机无样本，只做过合成样本验证。

Qwen 的 `thoughtsTokens` 不能一律再加到输出。核验上游 `QwenLM/qwen-code@99adce25e19dce4ea3bf90466ac84c8d6878becd`：

- `packages/core/src/telemetry/types.ts:404-425` 的 `ApiResponseEvent` 和 `packages/core/src/services/tokenUsageService.ts:231-255` 的 `apiResponseEventToTokenUsageRecord` 把 `candidatesTokenCount`、`thoughtsTokenCount` 分别写为 `outputTokens`、`thoughtsTokens`，不调整包含关系。
- `packages/core/src/core/openaiContentGenerator/converter.ts` 的 `convertOpenAIResponseToLlm`（1357-1474）和 `convertOpenAIChunkToLlm`（1491-2009）保留含 reasoning 的 `completion_tokens`，thoughts 取 reasoning 明细或文本估算；完整 completion 已包含 reasoning，明细不再相加。`openaiResponsesContentGenerator/responses-converter.ts:478-493` 的 `makeFinalResponse` 同样保留 `output_tokens` 与其 reasoning 明细；completion 缺失或仅有估算时不保证可还原完整输出。原生 Gemini 则把 candidates 与 thoughts 分列；无独立 tool-use prompt 时输出须相加，依据 [Gemini UsageMetadata](https://ai.google.dev/api/generate-content#UsageMetadata)（2026-11-01）。
- 最终规则（`PARSER_REV.qwen = 7`）：`authType` 为 `openai`、`openai-responses`、`qwen-oauth`、`anthropic` 时保留 rawOutput；未知输出且 thoughts>0 时取 thoughts 作为已知下界并记一次 `bad_fields`，无正 thoughts 则仍为 NULL。已知 rawOutput 小于 thoughts 时保留原值（含 0）并记一次 `bad_fields`，诊断先于零用量过滤。为 `gemini`、`vertex-ai` 时将 thoughts 并入 rawOutput。一项未知取另一已知项，两项未知才为 NULL。total 含 tool-use prompt 也不改变输出规则，不把该余量加到输出。适配器与 `scripts/audit/oracle/qwen.mjs` 按此规则分别独立实现，oracle 不 import 适配器。
- token 别名与优先级见 `log-schemas.yaml`：逐字段取第一个非 NULL/undefined 的值，0 不回退；接受非负整数与 trim 后的纯数字字符串，非法首选值不回退。仅 `inputTokens` 存在（含 NULL）时扣缓存，其他输入别名沿用未缓存口径；缓存未知不让已知输入变成 NULL，扣减结果下限为 0。oracle 独立遵守相同的四类 token 与零用量过滤规则。
- 认证映射依据同一上游 `utils/auth-type.ts:8-15`、`core/contentGenerator.ts:553-604`；`qwen/qwenContentGenerator.ts:25-43` 的 `QwenContentGenerator` 继承 OpenAI generator，`core/anthropicContentGenerator/usage.ts:44-64` 的 `buildAnthropicUsageMetadata` 保留完整 output 为 candidates，不另记 thoughts。
- `tokenUsageService.ts:219-228` 的 `calculateTotalTokens` 在 API total 缺失或为 0 时回填 `input + output + thoughts`，所以已知认证不依赖 total 判断包含关系。未知/缺失认证保留兼容规则：仅在 rawInput、rawOutput 都已知、total 为正安全整数且 `total = rawInput + rawOutput` 时保留 rawOutput，否则相加。这里 rawInput 是扣缓存前的输入；不能把该默认分列回退称作已证实的上游语义。

DSH 的「会话名前缀」是文件 stem 与生产会话 ID 的差异。`src/core/adapters/dsh.js:33-54` 取 `basename(file, '.json').replace(/^session-/, '')`，即 `session-<id>.json` 产生 `session_id=<id>`、`record_key=dsh|<id>`；无前缀时保留 stem，只剥开头一个前缀。身份不含 token、模型或时间。`record.identity` 对象只用于创建时刻与项目目录，不提供生产会话 ID。前缀来自文件名这一事实不等于已核验客户端原始 ID 的组成，上游文件名生成函数仍未确认。

`scripts/audit/oracle/dsh.mjs` 的身份规则已对齐生产适配器：同用上述 basename 与一次剥前缀规则，也不采用字符串 identity，不再产生 `session_filename_prefix`。同会话多份累计快照仍按结束时间与文件路径取最新一份。L3 历史归档中的 `session_identity_difference` 不代表当前 oracle 行为；全零快照保留与生产过滤的差异独立于身份规则，不改变 token 合计。生产适配器及历史身份未改。

`kind` 的判定：表/文件记录的是「整场结束后的汇总」→ `cumulative`；一条对应一次请求 → `event`。

OpenHands 只计能在本会话自己的事件里关联到的逐次用量。task、delegate、agent hook 的用量从子会话自己的记录读取，父会话里的副本不计；不按 usageId 前缀直接排除记录。发现从顶层会话沿 `subagents/<子会话>/` 逐层展开，不限深度、不跟随子目录链接，只读各层的 `base_state.json`；hook 的同级会话也由相同规则发现。`subagent_copies` 独立计数只用于未关联的三个已知前缀，不把正常父副本当作坏时间；新复制入口若无本会话事件仍不入账并计 `bad_times`。

三处如实标注为未确认，不猜：`gemini` 的 `$.id`、`trae` 的 JSONL `id`、`openclaw` 的 `row.id`。这三处保持各适配器原有回退行为，等有真实样本再定。

L5 键迁移经 `replaces` 指向旧键，沿用 schema v4 的停用与 `superseded_by`。无 id 的文件位置键不含用量，追加或原位增长不会新增身份；移动、截断或重排不能保证身份延续。已经丢失日志的旧键不能靠重采修复。

Goose 的 `sessions` 表缺 `provider_name` 列时，provider 存 NULL；Windows 同时发现 `%APPDATA%\goose\sessions\sessions.db` 与 `%LOCALAPPDATA%\block\goose\data.db`。`data.db` 的表结构未确认，适配器只读 `sessions`；只有 `usage_ledger` 的库不产出，尚未接入该表。

Goose 文件若只有 total，修正后整文件不产出；L1 的空产出保护不会停用其中的历史行。历史纠错仍须单独在账本副本上核对，不能用空产出来推断旧用量应当删除。

OpenClaw 的内容身份对规范化时间、原始 `row.id` / `message.id`、角色、正文（`content` / `text`）与 `tool_calls` 组成的数组做 SHA-256；编号仅作为原始内容参与指纹，不改变 `row.id` 的会话回退含义。用量和模型补录不改变键；同一身份跨文件的取舍沿用 `settleCopies`，合并副本的旧键。

Copilot 只有非零用量且时间有效的明细才覆盖汇总。明细用 `replaces` 停用同会话旧汇总；读取 `data.db` 时只读检查同目录 `session-store.db`，读取失败向上传播，避免拿汇总再计一遍。明细比完整汇总少时仍按明细计，不拼接未知余量；明细库删掉后，已被接替的旧汇总不会自动恢复。

待样本确认而不改取值：Zed 缓存包含关系、`request_token_usage` 是逐请求还是逐轮最新值；Continue 各候选输入字段的缓存包含关系；Aider `prompt_tokens` 是否含缓存写入；kimi 的 `prompt_tokens` 是否含缓存；Gemini thinking 是否并入输出；gemini / trae / openclaw 的 `row.id` 会话语义；cline / continue / cursor 的数据库路径是否是客户端实际写入位置。

旧的 `~/.mimo`、`~/.minimax/{sessions,logs}` 猜测路径不再发现，真实产品从未写过这些文件，因此账本里预计没有这些路径产出的行；若有，不会自动停用。

Cline 与 Roo Code（2026-10-26 读源码核实，未接入）：现有适配器读 `api_conversation_history.json` 中 assistant 消息的 `usage.*`，Cline 与 Roo Code 的源码里没有找到写入它的版本。各版本的实际用量位置：Cline 当前 SDK 版写 `<sessionId>.messages.json` 的 `metrics.{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`（input 含缓存读写），从旧任务迁移来的会话把整个会话的汇总挂在最后一条 assistant 消息上；3.39.2 起的经典版写 `metrics.tokens.{prompt, completion, cached}`，`cached` 是缓存读写之和，拆不开；更早的版本只在 `ui_messages.json` 的 `api_req_started` 里写 `tokensIn/tokensOut/cacheReads/cacheWrites`，`tokensIn` 是否含缓存随接口而变（Cline issue #11037）。Roo Code 最终版的 `tokensIn` 含缓存读写，但约 3.29.4 时改过一次口径，记录里没有版本标记，历史记录分不清。没有真实样本前不改取数。

## 四、证据现状

本机存在真实数据目录的客户端：

| source | 路径 | 条目数 | 已做真实样本对照 |
|---|---|---|---|
| `claude` | `~/.claude/projects` | 17 | **是**，1 条逐字段手核：`input 2 / output 637 / cache_read 458464 / cache_write 1282`，与原始 `message.usage` 逐项相等 |
| `codex` | `~/.codex/sessions` | 1 | **是**，25 条记录，缓存合计与客户端 `total_tokens` 对平 |
| `qwen` | `~/.qwen/usage` | 3 | **是**，20 条记录，归一后等于客户端 `totalTokens` 合计 1,483,257 |
| `dsh` | `~/.dsh/storages/session_projcache/sessions` | 96 | **是**（2026-10-26，L3 oracle）：有用量的会话文件四类 token 与客户端自报的会话 `totals` 逐项相等；全零的文件不入账 |
| `grok` | `~/.grok/sessions` | 3 | 否：只有 1 条用量事件，不足以对照 |
| `pi` | `~/.pi/agent/sessions` | 10 | **是**，30 条事件，四项 token 合计与原始字段一致 |
| `hermes` | `%LOCALAPPDATA%/hermes/state.db` | 1 | 否 |
| `kimi` | `~/.kimi-code/sessions/*/*/agents/*/wire.jsonl` | 48 | **是**（2026-10-26，`scripts/audit/oracle/kimi.mjs`）：按会话四类 token 与 oracle 相同；能配对上的 `usage.record` 四项之和全部等于客户端自测的 `token_counting.measured.tokens`，说明四项互不重叠。对照中查出 `subagent.completed` 的子 agent 汇总被重复计入、缺模型时写成 `moonshot-v1-8k`，已修（`parser_rev` 5） |
| `copilot` | `%APPDATA%/Code/User/globalStorage/github.copilot-chat/session-store.db` | 1 | 否：这是 VS Code Copilot Chat 的库，表为空，也没有用量列；适配器读的是 Copilot CLI 的 `~/.copilot` |

codex 桌面版（`originator` 为 `codex_work_desktop`）与 CLI 写同一个 `~/.codex/sessions`，现有适配器已经覆盖。

其余 18 组本机无样本，只能标 B。ZCode、MiniMax Code、MiMo Code 均按上游源码实现，经合成 SQLite 验证，本机无真实样本；MiMo Desktop 的路径仍只有第三方依据。对外说明写成「合成验证通过、现场待验收」，不写成已实测。

Command Code 按 npm 发布包 1.88.2 的 `appendMessage`、`toSessionUsage` 与 `estimateCatalogCostUsd` 定口径：inputTokens 含缓存读写；不另加 reasoning。`cacheWriteTokens1h` 是缓存写子集，合法时填 1h 与剩余 5m；非法记 bad_fields，未知存 NULL。追加文件中的所有已发生分支用量都计入，不按当前分支指针删掉历史请求。

AnythingLLM 按 9caf2b4c 的 `LLMPerformanceMonitor.measureStream` / `endMeasurement` 定口径：prompt 默认由 TokenManager 估算，reportedUsage 可覆盖 prompt/completion；记录不能可靠区分估算与实报，也没有统一缓存细分，缓存列存 NULL，不猜扣减。Prisma SQLite URL 固定 `file:../storage/anythingllm.db`，`STORAGE_DIR` 不是数据库覆盖变量；仅自动发现本机桌面库。workspace_chats 没有 workspace 外键，删除 workspace 由端点调用 WorkspaceChats.delete 批量删行；隐藏行也保留用量。

CodeBuddy 的路径、格式及包含关系仅来自第三方 NextAgentX/qoder-trae-workbuddy-switch 的 ab5afe42，未获官方或本机样本核实。输入按该解析器 Totals::value 扣缓存读，写入单列；prompt_cache_miss_tokens 不当作缓存写。CLI 不扫描 subagents，沿用第三方防止父上下文副本重复的范围；独有子任务用量是否因此漏计未确认。旧 sessions/logs 与 CODEBUDDY_HOME/WORKBUDDY_HOME 没有依据，不再发现；旧路径已入账行不会自动撤销。

真实样本夹具在 `test/fixtures/<source>/`；`pi` 的夹具只保留 `type`/`id`/`timestamp`/`message.usage`，正文已丢弃。

## 五、验收口径

每个适配器至少要有这 7 个用例，缺一不可：

1. 正常格式 → 数值与字段一致
2. 同一文件重复采集 → 行数与总额不变
3. 追加/增长 → 更新原行，不新增
4. 累计快照变化 → 覆盖，不累加
5. 轮转或截断 → 不重复计数
6. 坏行/缺字段 → 单独计数，不污染统计
7. 与客户端自报总量对照（客户端有自报时）→ 差额为 0

Command Code、AnythingLLM 和 CodeBuddy 的第 4 条不适用：它们只产出逐请求事件，没有会话累计快照。Command Code 和 CodeBuddy 的第 7 条不适用：已核实格式没有独立的逐请求自报总量；AnythingLLM 用 metrics.total_tokens 对照 prompt + completion，该总量本身由相同两项相加生成，不能充当独立语义证明。三个来源均有删行/截断后 active=1、总量不变的回归测试。

MiMo Code 的第 4 条不适用：message 表的 assistant 消息都是事件（kind = 'event'），库里没有整场会话的累计快照。第 7 条不适用：mimocode.db 只有逐条用量，没有客户端自报的会话总量字段，无法作独立总量对照。

## 六、对账状态（2026-10-18）

工具：`node scripts/audit/reconcile.mjs --out <path>`。只读账本与日志，报告写到工作区外。

它验的是**入库无损**：同一解析器把原始日志重放一遍，与账本逐条比 token / model / 项目归属。验不了**字段语义**——解析器与账本出自同一份代码，口径错了两边一起错。语义靠第五节式的逐字段手核。

可比条数按「重放与账本有共同身份」算，不是按重放条数算——重放里有一部分是账本还没采集的新记录，那些没有可比对象。

| source | 重放身份 | 未采集 | 可比条数 |
|---|---:|---:|---:|
| claude | 711 | 553 | 158 |
| codex | 1,546 | 295 | 1,251 |
| qwen | 89 | 90 | 0 |
| dsh | 11 | 11 | 0 |
| pi | 35 | 35 | 0 |

账本里其余记录的原始日志已不在磁盘上，无法重放，属于不可验证。

结论只能落在有可比条数的两个来源上：claude 158 条、codex 1,251 条，四类 token、model、项目归属零差异。qwen、dsh、pi 的现存文件与账本没有一条共同身份，**这三个来源本次一条都没验证过**，不能写成「一致」。

账本里大部分记录对应的原始日志已不在磁盘上，成了孤证。

「未采集」是账本落后于磁盘，跑一次采集即归零。

### 已解决：缓存写的档位（schema v2）

`claude` 的 `message.usage.cache_creation` 分 `ephemeral_1h_input_tokens` 与 `ephemeral_5m_input_tokens` 两档，单价不同（`claude-opus-5-5` 为 8.00 / 5.00 每百万 token）。此前账本只有 `cache_write_tokens` 一列，计价一律按 5 分钟档。

`SCHEMA_VERSION` 2 起：`usage_records` 增加 `cache_write_5m_tokens`、`cache_write_1h_tokens`，两者是 `cache_write_tokens` 的拆分，不进入 `gross_tokens`。`claude` 适配器在两档齐全且之和等于合计时写入分档；不一致或缺失时只报合计，计价回落到 5 分钟档。价目的 `cacheWrite1h` 按厂商 1 小时档填写。

去重口径：按唯一 `message.id` 统计，现存 726 条消息的缓存写全部是 1 小时档。直接对原始行求和会得到两倍多的数——同一条 message 的流式快照被写过多次，按行累加会翻倍。

升级兼容：v1 库升 v2 只加列，不重算历史行。用真实账本副本验证过——迁移后行数不变、新列为空、`reprice` 后总额一分未变。

影响面：若账本全历史的 claude 缓存写全部按 1 小时档，该分项的金额会增加六成。这是**上限**估计——历史记录的分档已不可知，现有 726 条样本全是 1 小时档，不能据此断定全部历史也是。

2026-10-19 真实账本已迁移到 schema v2：历史行数与总额一分未变、分档留空。同日补采的新 claude 记录全部带分档，两档都有，按档计价比一律回落 5 分钟档略高。新记录的分档并非全为 1 小时档，按实际上报档位计价才是对的。

### 待定位的计算差异

`dsh`、`pi` 的历史总量与另一种计算方式有差异，尚未定位到具体记录。需要逐文件、逐会话及时间桶证据继续核查；当前 oracle 与账本的核对结果不代表这些历史差异已经消除。

