// Source evidence and user-facing notes for desktop statistics.
pub const EVIDENCE: &str = r#"{
  "claude": "A",
  "codex": "A",
  "qwen": "A",
  "pi": "A",
  "dsh": "A",
  "kimi": "A",
  "mimo": "B",
  "minimax": "B",
  "zcode": "B",
  "codebuddy": "B",
  "commandcode": "B",
  "anythingllm": "B",
  "antigravity": "A"
}"#;
pub const SOURCE_LIMITS: &str = r#"{
  "claude": [
    [
      "分支或续接复制的消息只计一次",
      "同一条消息被分支或续接复制进另一个会话时只计一次，算在原始会话里。",
      "handled",
      "Messages copied by forks or resumes count once",
      "When a fork or resume copies a message into another session, it counts once in the original session."
    ]
  ],
  "codex": [
    [
      "cached ⊂ input，已在适配层扣减",
      "Codex 报的输入里包含缓存的部分，这里已经拆开，不会重复算。",
      "handled",
      "cached ⊂ input; subtracted in the adapter",
      "Codex includes cached tokens in input. They are separated here so they are not counted twice."
    ],
    [
      "同一 payload 并存三种累计表示，只取 usage",
      "同一份用量在日志里写了三遍，只取其中一份。",
      "handled",
      "Payload includes three cumulative fields; only usage is read",
      "The log reports the same usage three ways. Only one is used."
    ]
  ],
  "qwen": [
    [
      "输入含缓存，已扣 cachedTokens",
      "输入里包含缓存的部分，已经拆开。",
      "handled",
      "Input includes cache; cachedTokens is subtracted",
      "Cached tokens are counted separately from input."
    ],
    [
      "thoughtsTokens 是否已含在输出里，按 totalTokens 判断",
      "模型「思考」用的 token 按客户端自报的总数判断是否已经算在输出里，不会重复算。",
      "handled",
      "totalTokens determines whether output already includes thoughtsTokens",
      "The client-reported total determines whether reasoning tokens are already included in output, so they are not counted twice."
    ],
    [
      "条目 id 是条目身份，不是会话身份",
      "会话按日志里的会话编号归并，不按单条记录。",
      "handled",
      "Entry IDs identify records, not sessions",
      "Records are grouped by the session ID reported in the log."
    ]
  ],
  "dsh": [
    [
      "累计型：一个会话只有一条快照",
      "只记录每个会话的总数：看不到会话里每次请求的用量；会话跨天时，没法拆到每一天。",
      "affects",
      "One cumulative snapshot per session",
      "Only session totals are logged. Individual requests and daily usage for sessions spanning days are unavailable."
    ],
    [
      "模型缺失时不计价",
      "日志里没写模型时，这条用量不估算金额。",
      "affects",
      "Unpriced when model is missing",
      "Usage without a model name is counted without an estimated cost."
    ]
  ],
  "grok": [
    [
      "只有 turn_completed 带用量",
      "只有一轮对话完整结束时才写用量，中途打断的那一轮不计。",
      "affects",
      "Only turn_completed includes usage",
      "Only completed conversation turns have usage. Interrupted turns are omitted."
    ]
  ],
  "aider": [
    [
      "commit_hash 不作会话标识：一次提交不等于一场对话",
      "一次提交不等于一次对话，所以不按提交划分会话。",
      "handled",
      "commit_hash is not used as a session ID; one commit is not one conversation",
      "A commit is not the same as a conversation, so sessions are not grouped by commit."
    ]
  ],
  "pi": [
    [
      "会话头与用量不在同一行",
      "会话信息和用量写在不同的行，已经对上。",
      "handled",
      "Session header and usage are not on the same line",
      "Session information and usage are recorded on separate lines and matched during collection."
    ]
  ],
  "hermes": [
    [
      "累计型：一个会话一条快照",
      "只记录每个会话的总数，看不到每次请求。",
      "affects",
      "One cumulative snapshot per session",
      "Only the session total is logged. Individual requests are unavailable."
    ],
    [
      "两张表结构不同，优先细粒度表",
      "新旧两种日志都能读，优先用更细的那种。",
      "handled",
      "Two table schemas exist; the more detailed table takes precedence",
      "Both log formats are supported. The more detailed one takes precedence."
    ]
  ],
  "cline": [
    [
      "当前 Cline 与 Roo Code 的用量格式尚未接入",
      "读取的字段没有找到客户端写入的依据；新版 Cline 与 Roo Code 的用量存在别处，很可能一条都读不到。",
      "affects",
      "Current Cline and Roo Code usage formats are unsupported",
      "There is no evidence that clients write the fields read here. Newer Cline and Roo Code versions store usage elsewhere, so there may be nothing to collect."
    ],
    [
      "模型可能只在 ui_messages.json 里",
      "模型名有时只写在另一个文件里，已经一起读。",
      "handled",
      "The model can be in ui_messages.json only",
      "The separate file is also read when it contains the model name."
    ]
  ],
  "gemini": [
    [
      "输入含缓存，已扣",
      "输入里包含缓存的部分，已经拆开。",
      "handled",
      "Input includes cache; cached tokens are subtracted",
      "Cached tokens are counted separately from input."
    ],
    [
      "目录下混有非用量 JSON",
      "日志目录里混着别的文件，会自动跳过。",
      "handled",
      "Log directory includes non-usage JSON files",
      "Other files in the log directory are skipped automatically."
    ],
    [
      "会话 id 与条目 id 的语义未确认",
      "会话的划分方式还没完全确认，会话数可能偏多或偏少。",
      "affects",
      "Session and entry ID semantics are unverified",
      "Session counts may be too high or too low because the grouping is unverified."
    ]
  ],
  "cursor": [
    [
      "CSV 头部分列",
      "导出的表格表头格式不固定，已经兼容。",
      "handled",
      "CSV header columns vary",
      "Different exported table headers are supported."
    ],
    [
      "SQLite 是内部结构，版本变化风险高",
      "读的是 Cursor 自己的内部数据库，Cursor 升级后可能暂时读不到。",
      "affects",
      "Internal SQLite schema may change between releases",
      "Collection reads Cursor's internal database. An update may temporarily break collection."
    ]
  ],
  "opencode": [
    [
      "输出已并入 reasoning",
      "模型「思考」用的 token 算进了输出。",
      "handled",
      "Output includes reasoning",
      "Reasoning tokens are included in output."
    ],
    [
      "v1 / v2 表结构不同",
      "新旧两种版本的日志都能读。",
      "handled",
      "v1 and v2 table schemas differ",
      "Both versions of the log format are supported."
    ]
  ],
  "kilo": [
    [
      "旧版 JSON 任务目录未接入",
      "只读取新版数据库，旧版扩展的 JSON 任务记录暂未接入。",
      "affects",
      "Legacy JSON task directories are unsupported",
      "Only the new database is read. The older extension's JSON task records are unsupported."
    ],
    [
      "只计 session_message，输出并入 reasoning",
      "逐次消息只算一份，模型「思考」用的 token 算进输出。",
      "handled",
      "Counts only session_message; output includes reasoning",
      "Each message counts once. Reasoning tokens are included in output."
    ],
    [
      "开发 channel 数据库需显式 KILO_DB",
      "默认只发现 kilo.db，其他开发版本数据库需指定路径。",
      "affects",
      "Development channels require an explicit KILO_DB",
      "Discovery finds only kilo.db by default. Set the path for other development databases."
    ]
  ],
  "openhands": [
    [
      "SDK 自定义脚本、ACP 与服务端／容器／远程 runtime 未接入",
      "仅支持 OpenHands CLI 原生会话，其他运行方式暂未接入。",
      "affects",
      "Custom SDK scripts, ACP and server, container or remote runtimes are unsupported",
      "Only native OpenHands CLI sessions are supported; other runtimes are unsupported."
    ],
    [
      "时间取相同 response_id 的最早事件；无时区时间按采集机本地时区解释",
      "按响应事件时间归属日期；从其他时区搬来的日志可能归错日期。",
      "affects",
      "Timestamp uses the earliest event for each response_id; timestamps without offsets use local time",
      "Usage is dated by the response event. Logs moved between time zones may be assigned to the wrong day."
    ],
    [
      "只计能在本会话事件里关联到的逐次用量；子会话从自己的记录读取，父副本不计",
      "task、delegate 和 agent hook 的用量算在各自的子会话里，父会话中的副本不会重复算。",
      "handled",
      "Counts only per-request usage linked to this session's events; child sessions use their own records and parent copies are skipped",
      "Task, delegate and agent hook usage counts in each child session. Parent copies are excluded."
    ],
    [
      "未关联的 task:、delegate:、agent-hook: 条目计 subagent_copies，其余计 bad_times",
      "无法关联事件时间的用量不计入；已知子会话副本单独计数。",
      "affects",
      "Unlinked task:, delegate: and agent-hook: entries count as subagent_copies; other unlinked entries count as bad_times",
      "Usage without an associated event time is skipped. Known child-session copies are counted separately."
    ],
    [
      "只计 token_usages；prompt 扣缓存读写，completion 不再加 reasoning",
      "逐次记录只算一次，缓存和模型思考不会重复计算。",
      "handled",
      "Counts token_usages only; cache reads and writes are subtracted from prompt, and reasoning is not added to completion again",
      "Each record counts once. Cached and reasoning tokens are not counted twice."
    ]
  ],
  "goose": [
    [
      "累计型：只报累计总量",
      "只记录每个会话的总数，看不到每次请求。",
      "affects",
      "Only cumulative totals are reported",
      "Only the session total is logged. Individual requests are unavailable."
    ],
    [
      "accumulated_* 与 *_tokens 两套字段",
      "日志里有两套用量字段，只取其中一套，不会重复算。",
      "handled",
      "Two field sets exist: accumulated_* and *_tokens",
      "The two sets of usage fields describe the same usage. Only one is used."
    ],
    [
      "total 超出 input + output 的余量不入账",
      "日志里总数大于输入加输出的那部分含义不明，没有计入。",
      "affects",
      "Portion of total above input + output is excluded from the ledger",
      "Any amount above input plus output is excluded because the log does not explain it."
    ]
  ],
  "zed": [
    [
      "累计型：按 thread 覆盖",
      "只记录每个对话的总数，看不到每次请求。",
      "affects",
      "Cumulative snapshot overwritten per thread",
      "Only conversation totals are logged. Individual requests are unavailable."
    ],
    [
      "payload 可能是 zstd BLOB",
      "压缩存储的对话也能读。",
      "handled",
      "Payload may be a zstd BLOB",
      "Compressed conversations are supported."
    ],
    [
      "imported 线程未单独识别",
      "从别处导入的对话没有单独识别，和原对话同时存在时可能重复计。",
      "affects",
      "Imported threads are not identified separately",
      "Imported copies may count twice if the original conversations are also present."
    ],
    [
      "输入是否含缓存未确认，未扣减",
      "输入里是否包含缓存还没确认，暂未拆开；如果包含，缓存部分会按输入再算一次。",
      "affects",
      "Cache inclusion in input is unverified; not subtracted",
      "Whether input includes cache is unverified, so they are not separated yet. If included, cached tokens are counted again as input."
    ]
  ],
  "continue": [
    [
      "单文件多轮，逐轮取用量",
      "一个文件里有多轮对话，逐轮读取。",
      "handled",
      "Single file with multiple turns; usage is read turn by turn",
      "Each turn in a conversation file is read individually."
    ],
    [
      "输入是否含缓存未确认，未扣减",
      "输入里是否包含缓存还没确认，暂未拆开；如果包含，缓存部分会按输入再算一次。",
      "affects",
      "Cache inclusion in input is unverified; not subtracted",
      "Whether input includes cache is unverified, so they are not separated yet. If included, cached tokens are counted again as input."
    ]
  ],
  "trae": [
    [
      "JSONL 行里 id 的语义未确认，保留原有回退",
      "记录编号的含义还没完全确认，个别记录可能被合并或拆开。",
      "affects",
      "JSONL entry ID semantics are unverified; existing fallback is kept",
      "Some records may be merged or split because entry IDs have unverified meaning."
    ]
  ],
  "copilot": [
    [
      "输出已并入 reasoning",
      "模型「思考」用的 token 算进了输出。",
      "handled",
      "Output includes reasoning",
      "Reasoning tokens are included in output."
    ],
    [
      "同一会话优先明细，汇总库仅补充无明细的会话",
      "同一会话有逐次用量时只取逐次用量；其余会话取总数。",
      "handled",
      "Request details take precedence per session; summary database fills in sessions without details",
      "Individual usage records are used where available, and session totals for other sessions."
    ]
  ],
  "openclaw": [
    [
      "归档与活跃日志中内容身份相同的事件只计一次",
      "同一份消息副本只计一次；时间、编号和正文都相同的消息无法进一步区分。",
      "affects",
      "Events with the same content identity across archive and active logs count once",
      "Identical messages count once. Matching timestamps, IDs and text provide no way to distinguish them."
    ]
  ],
  "mimo": [
    [
      "删会话会级联删除消息，账本保留已采集用量",
      "MiMo Code 删除会话后，已经采集的用量仍计入总数。",
      "handled",
      "Session deletion cascades to messages while collected usage stays in the ledger",
      "Usage already collected stays in the totals after MiMo Code deletes a session."
    ],
    [
      "显式启用 channel 库时，同目录备份库可能共享消息 id",
      "只有设置 MIMOCODE_DISABLE_CHANNEL_DB=false/0 才读取 mimocode-*.db；同目录备份库可能与正式库共享消息 id，用量不同时可能采用较旧的一份。",
      "affects",
      "When channel databases are explicitly enabled, backup databases in the same directory may share message IDs",
      "mimocode-*.db is read only when MIMOCODE_DISABLE_CHANNEL_DB=false/0 is set. Backups in the same directory may share message IDs with the main database, so conflicting usage may use an older copy."
    ],
    [
      "MiMo Desktop 路径来自第三方，未核实",
      "桌面版的日志位置尚未由官方源码或真实样本确认，可能读不到。",
      "affects",
      "MiMo Desktop paths are unverified third-party references",
      "The desktop log path lacks verification from official code or real samples, so logs may not be found."
    ]
  ],
  "kimi": [
    [
      "目录层级不统一",
      "不同版本的日志目录层级不一样，都会去找。",
      "handled",
      "Log directory layouts vary",
      "Discovery checks the layouts used by different versions."
    ],
    [
      "wire 只计 usage.record，subagent.completed 的汇总不另计",
      "子任务的用量只按它自己的记录算一次，不会和主任务里的汇总重复。",
      "handled",
      "wire counts usage.record only; subagent.completed summaries are skipped",
      "Child-task usage counts once from its own records. Its summary in the parent task is excluded."
    ]
  ],
  "minimax": [
    [
      "rewind 与删会话会删除用量行，账本保留已采集用量",
      "MiniMax Code 回退对话或删除会话后，已经采集的用量仍计入总数。",
      "handled",
      "Rewinds and session deletions remove usage rows; collected usage stays in the ledger",
      "MiniMax Code rewinds and deletions leave previously collected usage in the totals."
    ]
  ],
  "codebuddy": [
    [
      "路径与格式来自第三方逆向解析器",
      "按第三方解析器读取 CLI 的 projects 和桌面版会话索引，待真实样本核实。",
      "affects",
      "Paths and formats come from a third-party reverse-engineered parser",
      "Collection uses a third-party parser's CLI projects and desktop session index formats. Real samples have yet to verify them."
    ],
    [
      "输入含缓存读，已扣；prompt_cache_miss_tokens 为未缓存输入",
      "缓存读取已拆开，未命中缓存的输入不会当作缓存写入。",
      "handled",
      "Input includes cache reads (subtracted); prompt_cache_miss_tokens is uncached input",
      "Cache reads are counted separately. Uncached input does not count as cache writes."
    ],
    [
      "CLI 无已验证消息 ID，身份依赖文件路径与物理行号",
      "CLI 日志移动或重排后可能重复计数；桌面请求有 ID 时按请求去重。",
      "affects",
      "CLI identity uses the file path and line number because message IDs are unverified",
      "Moving or reordering CLI logs can duplicate usage. Desktop requests with IDs are deduplicated by request."
    ]
  ],
  "commandcode": [
    [
      "只读 command-code 1.88.2 的 v3 transcript，不读伴生文件",
      "仅接入带逐条用量的 v3 会话格式，旧版格式尚未接入。",
      "affects",
      "Reads only command-code 1.88.2 v3 transcripts; companion files are skipped",
      "Only v3 sessions with per-request usage are supported. Older formats are unsupported."
    ],
    [
      "输入含缓存读写，均已扣除",
      "输入与缓存分开计算，同一条请求重复采集不会增加用量。",
      "handled",
      "Input includes cache reads and writes; both are subtracted",
      "Input and cache usage are separate. Recollecting a request does not add usage."
    ]
  ],
  "anythingllm": [
    [
      "prompt/completion 可能是估算值，也可能被 provider 返回值覆盖",
      "客户端可能用本地估算的 token 数；无法逐条区分估算与实际返回值。",
      "affects",
      "prompt/completion may be estimates or overwritten by provider counts",
      "The client can estimate token counts locally. Individual estimates cannot be distinguished from provider counts."
    ],
    [
      "缓存无可靠细分，缓存读写存 NULL",
      "日志未提供统一的缓存拆分，缓存部分无法独立计价。",
      "affects",
      "No reliable cache breakdown; cache reads and writes are stored as NULL",
      "The logs lack a consistent cache breakdown, so cache costs cannot be estimated separately."
    ],
    [
      "include=false 仍计入；删 workspace 后保留已采集用量",
      "隐藏或删除聊天记录不会撤销已经发生并采集的用量。",
      "handled",
      "include=false is still counted; collected usage stays after workspace deletion",
      "Hiding or deleting a conversation leaves previously collected usage in the totals."
    ],
    [
      "STORAGE_DIR 不覆盖 Prisma SQLite URL，仅自动发现本机桌面库",
      "服务端数据库和容器内的数据库不在自动发现范围内。",
      "affects",
      "STORAGE_DIR does not override the Prisma SQLite URL; only the local desktop database is discovered automatically",
      "Server and container databases are outside automatic discovery."
    ]
  ],
  "antigravity": [
    [
      "逐次生成记一条，输入不含读缓存",
      "每次模型生成记一条用量。agy 记的输入已经去掉了读缓存，读缓存单独计；输出包含思考 token。",
      "handled",
      "One record per generation; input excludes cache reads",
      "One usage record per generation. agy excludes cache reads from input and counts them separately; output includes reasoning tokens."
    ],
    [
      "不报告写缓存",
      "agy 的数据里没有写缓存，这一项显示为不记录。",
      "affects",
      "Cache writes are not reported",
      "agy does not report cache writes, so this field shows as Not logged."
    ],
    [
      "项目取会话的工作区",
      "项目来自 agy 记录的会话工作区；没有记录工作区的会话不归到任何项目。",
      "handled",
      "Project comes from the session workspace",
      "Projects come from the session workspace recorded by agy. Sessions without a workspace are unassigned."
    ]
  ],
  "zcode": [
    [
      "客户端只保留 30 天用量",
      "首次采集时，只能读到 ZCode 最近 30 天仍保留的用量。",
      "affects",
      "The client keeps 30 days of usage",
      "The first sync can collect only the last 30 days of usage still kept by ZCode."
    ],
    [
      "多库同一请求 id 的用量不同时可能采到旧值",
      "默认库与自定义或迁移后的库并存且请求 id 相同时，账本按副本规则只采一份；若在请求进行中复制库，导致同一 id 的 token 不同，可能采到较旧的一份。上游 model_usage 行在请求完成时写定，正常使用中两份库对同一 id 的值一致。",
      "affects",
      "Conflicting usage for one request ID across databases may use the older copy",
      "When the default database and a custom or migrated one share a request ID, only one copy counts. If a database was copied mid-request with different token counts, the older copy may be used. Upstream model_usage rows are finalized when a request completes, so values normally match across copies."
    ],
    [
      "剪枝不撤销已采集用量",
      "ZCode 清理旧记录后，已经采集的用量仍计入总数。",
      "handled",
      "Pruning keeps previously collected usage",
      "After ZCode prunes older records, previously collected usage stays in the totals."
    ]
  ]
}"#;
