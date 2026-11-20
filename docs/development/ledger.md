# 账本契约

账本是应用数据目录下的 SQLite 文件 `ledger.db`。本文写明用量表 `usage_records` 每一列的含义和必须保持的不变式。适配器、入账和查询都按这里的规则实现；规则来自旧版 Node 工具，桌面版沿用，所以记录身份、内容哈希和价表版本与旧版逐字节一致。结构版本和迁移见 [stats.md](stats.md) 的 v6、v7 两节，计价见 [pricing.md](pricing.md)。

## `usage_records` 的列

| 列 | 含义 |
| --- | --- |
| `record_key` | 记录的稳定身份，同一个键就是同一条记录。不得包含 token 数。 |
| `content_hash` | 判断同一条记录现在报出的内容是否变了。参与计算的有：`kind`、模型、四类 token、`observed_at`、`ended_at`、`session_id`、写缓存的分档，以及非 NULL 的 `provider`。`provider` 为 NULL 时不加任何输入和分隔符，保持 v4 的哈希不变。项目不参与：新识别出的项目直接在原行改标签。实现在 `app/rust/src/stats/ledger/mod.rs` 的 `payload_hash`。 |
| `kind` | `event`（一次请求）或 `cumulative`（会被整体改写的会话快照）。 |
| `ended_at` | `cumulative` 快照覆盖的最后一次活动；`observed_at` 是会话开始时刻。NULL 表示未知。快照的开始和结束落在同一个时间桶里就计入这个桶，否则计入 `unallocated`。v3 加入，下次采集时补上。 |
| `input_tokens` … `cache_write_tokens` | NULL 表示未知。未知不是零。 |
| `provider` | 日志里明确写出的服务商 ID；NULL 表示未知。v5 加入，旧行不回填。绝不从模型名、路径或客户端推断。非 NULL 时进入内容哈希，所以重读一份带服务商的日志会让该行更新一次。`pricing-catalog.json` 的 `localProviders` 里的本地服务商按小写匹配，金额记零、四个分项都是零，`price_source` 为 `local:<小写 ID>`。 |
| `cache_write_5m_tokens`、`cache_write_1h_tokens` | 写缓存的分档，是 `cache_write_tokens` 的子集，按不同价格计价。NULL 表示客户端没有分档，计价时把 `cache_write_tokens` 全按 5 分钟档算。v2 加入；只有从报告了分档的日志重读时才补上，日志已经不在的行不猜。 |
| `project_key` | 客户端报告的工作目录。它是路径，不是标签；日志里从没写过时为 NULL，适配器不得从文件路径猜。 |
| `revision`、`active`、`superseded_by` | 记录增长时原地更新，不删除任何行。只统计 `active = 1` 的行。两种情况会让一行失效：新版解析器从同一个文件不再产出它；或者一条新身份的记录在 `replaces` 里点名了它的键，这时 `superseded_by` 指向新行。 |
| `source_file`、`parser_rev` | 最后一次产出这一行的日志文件和解析器版本。v4 加入；之后没被重读过的行为 NULL，这些行不会被停用，按版本 1 算。 |
| `price_version`、`cost_micros`、`price_source` | 金额用整数微美元（USD × 10⁶）。 |

解析器版本在 `app/rust/src/stats/adapters/mod.rs` 的 `PARSER_REV`。某个来源的数值、身份或时间有任何变化，就要升它的版本。这条只管用量记录；请求计时用同一文件里每个来源自己的 `TIMING_REV`，升计时版本不动用量版本。

## 不变式

- `gross_tokens = input + output + cache_read + cache_write`，四类互不重叠。SQL 里要每列分别求和再相加，或者给每列套上 `coalesce`；`sum(a + b + c + d)` 只要有一行某列为 NULL 就整体返回 NULL，看起来像“没有数据”，实际只是有一列未知。写缓存的分档列是 `cache_write_tokens` 的拆分，不是第五类：两档之和必须等于它，也不单独进入 `gross_tokens`。
- 客户端报的是含缓存的总数时，由适配器减掉缓存部分，查询层从不调整 token 数。
- 一个事件只出现一次。同一来源的几个文件里出现同一条事件记录时（分支或恢复的会话会复制之前的消息），入账只从开始得最早的那个文件写入，让它留在原来的会话里；其余副本记为 `cross_file_copies`，不算从它们的文件里消失。会话快照不这样合并。
- 重读一条记录不会产生第二行。增长的 `event` 记录更新原行；`cumulative` 记录直接覆盖；`cumulative` 变小只在解析器版本变了时才接受，否则记为异常并保留原值。同一版本下记录从文件里消失记为 `vanished`，照常计数：客户端清理日志不会撤销已经用掉的量。
- 按任何维度分组，各组之和等于总数，token 和金额都是。各时间桶加上 `unallocated` 桶也等于总数。

## 其他表

- `usage_timings`（v6）：每次请求的计时，与用量行分开存放，不影响用量和金额。口径见 [stats.md](stats.md)。
- `ingest_files` 等文件缓存表（v7）：记录每个日志文件上次读到的状态，用来跳过没变的文件。来源页的“重新读取全部日志”会忽略它重读一遍，但不清空账本。
- `legacy_records`：旧版从更早的 `data.db` 导入的记录，只读保留，从不计入当前总数。
