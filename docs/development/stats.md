# 统计迁移（D3）

## 阶段与边界

D3 把统计内核和看板从 Node/React 移到桌面预览的 Rust 核心和 Flutter 界面。旧版是 D3 的行为基线：仓库 `1ce3446` 的 `src/core`，运行时 Node v24.22.1，账本 schema v5。

- 账本：D3 沿用 schema v5，E4a 桌面版在保留用量表的基础上升到 v6（见下文）（[ledger.md](ledger.md)）。`record_key`、`content_hash`、价表版本与旧版逐字节一致，新版能直接打开旧版账本的副本。
- 适配器：27 个全部迁移，分三批（见「子阶段」）。
- 界面：照现有看板的结构搬（总览、明细、会话、来源、设置与价格），只有和现有界面不同或拿不准的地方先做原型。
- 数据：D3 的账本放在预览目录，D3 期间从不打开、读取或写入 `~/.token-lens`，也不读 `TOKEN_LENS_DATA_DIR`、`DB_PATH`。真实账本的副本迁移和切换属于 D4，每一步单独确认。
- 联网：统计不联网。汇率更新沿用旧版的规则：只在用户点击时请求（[features.md](../archive/features.md) G14–G16）。

## 统计界面显示

- 总览重试期间保留上一次数据及其失败提示；本次完整结果到齐后统一发布数据和错误，成功的资源清除错误，失败的资源更新错误。过期读取不更新界面。首次加载的骨架屏及已有数据的保留方式不变。
- 总览、明细和会话共用一个查询缓存（`app/lib/stats_cache.dart`），包在统计网关外面。缓存 `summary`、`timeseries`、`matrix`、`breakdown`、`sessions`、`querySessions`、`sessionDetail`、`comparison`、`pricing`、`sources`、`requestList`，键为方法名和全部参数（含筛选的每个字段），最多保留 128 条，按最近使用淘汰；相同查询进行中时共用一次请求，失败不缓存。账本版本（`ledgerVersion`）每次变化都整体清空，包括同步成功、同步失败（可能已提交部分文件）、全量同步中途的刷新和同步状态复查读到的任何终态；本地日期或传给 Rust 的时区偏移变化时也清空，`summary().rolling` 等按查询时刻计算的字段因此不会跨日沿用。界面上的重试先清空再读。同步状态复查和来源页直接读，不经过缓存：`sources()` 里的日志保留情况和异常检查按读取时的文件状态计算，同步之间移动或删除日志会改变它们，所以总览和会话页使用的来源快照在这种情况下可能与来源页不同，下一次账本变化后一致。
- 首次引导完成后，总览当前时段加载成功，就在后台依次预取今天、本周、本月、全部的总览数据（跳过当前时段和已缓存的查询），一次一个时段；切换时段、开始同步或状态复查、关闭窗口时停止。预取不改偏好、不发通知、失败不显示。命中缓存的时段切换不显示加载状态。
- 项目显示最后一级目录；同一列表内有不同完整路径使用同名目录时，显示“上一级 / 名字”。明细、会话与项目筛选的完整路径通过悬停查看。
- 会话开始、详情与明细日期使用传入的时钟：今天、昨天用相对说法；今年其他日期为“11月15日 周日”，跨年为“2025年11月15日”。小时不补零；会话详情按天日期首行显示“11月17日 周二”，不折行，今天和昨天在下一行用较小的灰色文字标明，其他日期只有首行。请求列与同表其他数字使用相同字号和颜色。
- 会话详情标题由读取到的项目决定，没有项目时为“工具名 会话”（如“Kimi 会话”），会话列表里仍显示“没有记录项目”。副标题为“工具名 · 今天 9:12 开始 · 持续 3 小时 20 分”；持续满 24 小时后改写为“4 天 23 小时”，整天只写“5 天”。从地址直接打开也遵循此规则。
- token 构成和总量使用相同的缩写函数，跟随“万 / 亿”或“K / M / B”的设置。百分比共用 `percentage()`，侧栏本期工具占比同样遵循此规则：只有精确的 0 与 100% 显示整数边界；接近边界的非整数值保留一位小数，并维持在边界以内。
- 表格和卡片在窗口宽度 1440、1024、720 下保持内容在卡片内；明细空间不足时使用紧凑行，请求数标为“1,234 次请求”。名称单行显示，长名称省略并提供完整名称悬停提示；桌面价格表模型列至少完整显示 `claude-sonnet-5-5`、`gemini-3.8-flash-k`、`kimi-code/k3.1-pro`，剩余宽度给价格说明。热力图悬停日期、请求数、累计用量表头与来源卡副标题中的各项不从中间折行；副标题的“ · ”跟随前一段换行。说明文字的结尾连在一起，避免孤字。
- 明细宽表与紧凑行共用排序字段和方向，切换窗口宽度时保留排序。紧凑行上方提供“排序：用量”这样的筛选式下拉和方向按钮，方向提示为“从大到小”或“从小到大”；选项包含当前维度名称、用量、约值、占比、新输入、输出、读缓存、写缓存、请求和平均每次。紧凑行的四个 token 构成项两两成组换行。
- 只有本次来源读取成功、结果已发布且全部来源记录数为 0，才判为全空账本。此时首页副标题为“同步之后，这里会显示每个 AI 编程工具用了多少 token。”；空态卡片显示“还没有任何用量”，说明“Token Lens 读取 AI 编程工具的日志。去「工具」页看看找到了哪些工具，或者立即同步。”，操作为“立即同步”（主按钮）“查看工具”，底部注明“只读取本机日志，不上传任何内容，也不改动这些工具。”。卡片中列出本机发现的工具和各自的日志文件数，最多 6 个，其余合并为“还有 N 个”；发现结果按同步版本缓存，只在全空账本时读取；一个也没找到时改为“这台电脑上还没找到支持的 AI 编程工具”，读取失败时不显示这一块。总览、明细和会话在全空账本时共用这张卡片，并隐藏时段控件。仅当前时段没有记录、来源读取失败或等待重试结果时仍提供切换时段；全零趋势纵轴只标 0，其余纵轴标签不重复。
- 「工具」页（侧栏同名）列出当前系统支持的全部 28 个工具，按已找到、有问题和没装分组；筛选为“全部”时不显示数量为 0 的分组。候选路径和文件数来自发现规则，没装组默认折叠。路径可搜索、复制，存在的目录可打开。用户主目录下的路径显示为 `~` 加其余部分（主目录取 `USERPROFILE` 或 `HOME`，不区分大小写，前缀后必须是分隔符），过长时保留开头和最后两段、在分隔符处省略；悬停、复制和打开用完整路径。展开行可看各目录状态、日志留存、自检、已知限制和技术细节。
- “显示”开关写入 `ui-preferences.json` 的 `hiddenTools` 来源 ID 数组。缺失时视为空数组，未知 ID 原样保留。总览、明细、会话和侧栏使用同一组排除条件；隐藏当前筛选或面板所指的工具时，清除该筛选或关闭会话面板。来源、价格设置、采集、账本、CLI 与导出仍使用完整数据。
- 总览、明细、会话在常规同步期间显示标题胶囊。完成后胶囊显示“已同步”并在 4 秒后消失。首次同步及重新读取全部日志使用进度横幅，已提交的工具可在同步期间浏览。失败和异常横幅可跳转到「工具」页或按本次同步关闭。
- 价格表按累计 token 从多到少、等量时按模型名排列。长提示行显示“超过 27.2万 token 的长提示按更高价算：7 次”，分时行显示“按时段计价：3 次在低谷时段”；对应次数为 0 时隐藏该摘要，展开说明仍保留。提示长度、基础档、区间加权、周占比与节假日登记范围留在展开说明中。价格随软件内置，不联网也能用。
- 设置顺序为「外观与界面 → 数字与时间 → 联网与更新 → 价格 → 诊断与关于」。诊断和本机信息共用最后一张卡。首次引导使用侧栏的正式标志。
- `ui-preferences.json` 的 `density` 为 `comfortable`（默认）或 `compact`。紧凑模式将总览卡片、明细和请求表、会话行、来源清单等处的部分内边距和行距乘以 0.75，字号不变。`uiScale` 为 0.9、1.0（默认）、1.1 或 1.25，在系统显示缩放基础上乘以该比例。界面布局按缩放后的可用尺寸响应。
- `defaultPeriod` 为 `last`（默认）、`today`、`week` 或 `month`。只在启动时选择本轮的总览和明细时段。手动选择继续写入 `period`，供下次按「上次用的」启动时读取。
- `weekStart` 为 `monday`（默认）或 `sunday`。用于本周的起点、同期上周的起点、本周经过天数、按星期绘制的轴范围与热力图行序。旧偏好文件缺少该字段时，热力图首行从周日调整为周一。本周和上周的既有周一计算沿用，CLI 继续从周一起算。新增字段缺失或非法时各自回退到默认值。
- 键盘焦点为 1.5px 陶土色描边，紧贴控件外缘；仅在控件获得焦点且最近一次输入来自键盘时显示。鼠标、触控板或触摸按下会隐藏描边，包括鼠标打开详情后自动聚焦的关闭按钮；后续键盘操作恢复描边。Tab 先按导航、本期工具、底部按钮的顺序走完侧栏，再按页头提示条、标题旁控件、筛选、正文内容的顺序移动；导航抽屉打开时在抽屉内循环，关闭按钮排在底部按钮之后。关闭详情使用中性图标按钮。
- 总览、明细和会话的时段控件在「全部」与日历之间提供「更多」。`yesterday` 对前天，两边各一天，趋势按小时。`lastWeek` 为按 `weekStart` 划分的前一个完整周，对再前一周，趋势按星期。`lastMonth` 为前一个自然月，对再前一个自然月，比较整月用量。`last7`、`last30` 含今天，比较紧邻起点的等长区间。日期首尾包含，跨月和跨年按日历计算。新增五档可写入已记住的 `period`，默认时段选项仍为 `last`、`today`、`week`、`month`。
- 会话地址支持 `q`、`sort`、`dir`。搜索约 250 ms 防抖，与当前时段、项目、模型、工具与隐藏工具筛选取交集。默认按时段内用量降序，另可按约值、开始时间、最近活动或时段内请求数排序。开始时间与最近活动取整个会话。排序下拉和表头使用同一地址状态。会话和明细的工具、模型、项目下拉在超过 8 项时可按显示名搜索。
- 会话页的时段控件与总览、明细一样位于页头右侧。会话行第二行为“工具名 · 会话 ID 最后 8 个字符”（不足 8 个显示全部），点击复制完整 ID，不打开详情。所选时段之前就开始的会话在名字旁显示中性徽标“跨时段”，悬停显示“开始于 10月30日”；总览“本周的会话”卡片没有开始列，仍显示“开始于 …”。徽标与名字同行，名字过长时截断名字。
- 总览“这一年”热力图按所选范围内有用量的天取 P25、P50、P75 分为 1–4 档（线性插值，阈值取整，落在边界归入较低一档），没有用量的天为 0 档；有用量的天少于 8 天时按占最大值 25%、50%、75% 分档。图例每格悬停显示该档 token 区间，最高档写“N token 以上”。
- 内容区最大宽度 1440（含左右内边距）。总览宽屏双栏（趋势和常用模型、这一年和本周的会话）为 13:7，窗口 1180 宽时仍为单栏。会话表首列宽度上限 280，按内容分配。新闻页文章列表保持自己的宽度。
- 首次引导完成页内容垂直居中，过高时从顶部滚动。三格数字的 token 格单位行为“token · 约值 $180”；下方“按工具拆开”卡片按 token 降序列出各工具的占比条（分类色）、token、占比和约值，最多 5 行，超过时第 5 行汇总为“其他 N 个工具”。数据来自与 `summary` 并行的 `breakdown('source')`，失败或为空时不显示卡片。
- 总览用量的今天与整个昨天比较，本周和本月与同进度比较。环比徽标可以打开右侧归因面板，默认按项目显示前五项，也可按工具、模型展开，按所选指标差额绝对值排序。归因各行按上期 → 本期显示数值。归因和明细都用界面语言显示两期日期，天数不同时才标天数。总差额至少 10% 时，总览文字取和总差额同方向、差额绝对值最大的已记录项目，并使用当前数字单位。明细地址 `compare=1` 显示上期和差额，可按差额排序。本期未用的行在约值、请求和平均每次列显示「—」。时间和请求拆分中开启对比时进入项目拆分。归因行跳到明细时保留时段与分组筛选。
- 总览和明细趋势分别记住当前页面的 token 或金额切换。金额柱与平均线使用已定价记录的整数微美元，工具颜色与 token 模式相同。金额模式显示未定价提示，金额归因同样只计算已定价部分。
- 代表工具的颜色跟随图标：16 个工具（Claude Code、Codex、Qwen Code、Antigravity、DSH、Gemini CLI、Copilot、OpenClaw、CodeBuddy、ZCode、MiniMax Code、Trae、OpenHands CLI、Aider、Continue、Zed）在 `palette.dart` 各有浅、深两套固定色，有彩色图标的取图标主色，Aider、Continue、Zed 没有图标，固定色用在字母磁贴上。其余工具（图标是黑白的、没有图标的 AnythingLLM，以及表里没有的新工具）用五档墨色，按当前视图里的 token 用量从多到少取档，用量相同按工具 ID，第五个以后共用第五档；各页按自己显示的数据排：总览按本期工具用量，侧栏按侧栏本期用量，明细趋势按当前查询的工具矩阵（金额模式也按 token），会话按已加载的会话，首次引导按完成页的工具。总览和明细趋势仍按工具首次出现的顺序堆叠。总览「常用模型」和会话详情「用了哪些模型」的模型条用所属工具的颜色（总览取该模型用量最多的工具，档位与总览工具条一致；会话详情取会话的工具，与面板磁贴同色），同一工具的几个模型同色。明细表格的占比条、其他按模型或项目拆分的图表和会话详情的 token 种类仍用 `cat-*` 通用色序，「其他 N 个工具」合并项用 `cat-other`。没有图标时字母磁贴用工具色作底色，墨色工具用第一档。新增彩色图标时要在浅、深两套主题里同时登记工具色。

价格查询的模型顺序按累计 token 排列，与 Node 基线按记录数的顺序不同；每个模型的字段、计数和价格仍保持对拍。

- 启动失败按错误代码说明原因：`already_running`、`app_files_missing`、`data_dir_denied`、`disk_full`、`ledger_corrupt`、`ledger_too_new`、`startup_failed`。Rust 在仍保留错误类型的地方分类（io、SQLite、账本版本检查），以 `<代码>: <原始信息>` 跨 FFI 传给界面，`ledger_too_new` 另带账本版本和程序支持版本；`app_files_missing` 由界面在 Rust 动态库加载失败时判断。运行日志和同步结果的错误类别使用同一套代码，命令行的 JSON 错误代码和退出码不变。
- 应用整个打不开时显示启动失败页：图标、标题、说明和步骤随错误代码变化，`data_dir_denied` 和 `disk_full` 另显示数据目录；按钮为「导出诊断日志」「打开日志文件夹」「关闭」，主按钮随原因变化（权限、账本损坏、其他是导出；已在运行、磁盘满、版本过新是关闭）。`app_files_missing` 只有「打开程序所在文件夹」和「关闭」，因为没有核心就导不出诊断。可折叠的「详细信息」显示错误代码、版本、数据目录和原始信息。Windows 上再次启动时由单实例互斥锁把已有窗口切到前台，`already_running` 页只在互斥锁拦不住而数据目录锁被占用时出现。
- 应用能开但统计账本打不开时，侧栏照常显示，总览位置显示同一张失败卡片（无「关闭」）；明细、会话、工具、价格与设置置灰且不可聚焦，AI 热点随新闻开关可用，开着时卡片注明「AI 热点仍可使用」，侧栏底部写「统计不可用」。
- 运行日志（`logs/token-lens-<日期>.log`）由后台线程写入：调用方只做脱敏、换行转义并放进队列就返回，不等进程内或跨进程的写锁。同一线程提交的行按顺序落盘，锁竞争不再丢行。队列每进程最多 4096 行、16 MiB，超出时丢弃新来的行，并在下一次能写下时补记一行 `WARN runtime dropped N runtime log lines (queue full)`。应用退出时写完 `exit` 后最多等 200 ms 刷写，设置页和启动失败页导出前最多等 200 ms，命令行正常返回前最多等 2 s；超时不取消后台写入，但进程结束时尚未写入的行会丢失。每日文件、保留 7 天、5 MiB 上限与截断标记、脱敏和链接保护不变。
- 启动失败时的诊断导出不打开账本写入、不创建数据目录：包含版本、提交号、系统、数据目录、错误代码和脱敏后的原始信息、各工具找到的日志文件数、最近 7 天运行日志；账本能以只读方式打开且版本正确时附最近 10 次同步，否则写「账本：无法打开（<错误代码>）」。文件名与设置页的导出相同，存到下载文件夹，拿不到时退到已存在的数据目录下的 `exports`。

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
3. **旧版文档与代码不一致的地方以代码为准**，例如 `docs/development/adapters.md` 里 Claude 的旧键写法、Grok/Aider/Goose/Zed 在 `log-schemas.yaml` 里的描述。迁移只搬现状，不修复字段语义；语义修复等真实样本，并且要升 `PARSER_REV`。
4. **会话游标**。`jscompat` 自己实现 base64，只接受解出来是非负十进制整数的游标。`Number()` 才接受的写法（十六进制、科学计数、前后空白）按无效处理，从头开始。游标只来自 `next_cursor`，不影响正常翻页。
5. **`health`**。没有 HTTP 服务，因此去掉 `port`，版本号取 Rust crate 的版本，字段是 `ok`、`version`、`data_dir`、`ledger_path`、`schema_version`。这一项不对拍。
6. **会话详情的粒度**。FFI 上 `granularity` 必填，只接受 `hour` 或 `day`，不设默认值。
7. **Codex 不可靠响应 ID**。Rust 身份规则自 `PARSER_REV=5` 起，E4a 计时独立使用 `TIMING_REV=1`，Node 回滚路径仍为 4，分别写独立账本。可靠 id 的 key 字节不变；只按 id 形状判定，去掉开头 `resp_` 后为空、全 ASCII 数字或少于 16 字符的 id 不可靠，判定不依赖文件内容，部分历史副本也保持相同身份。Rust 用 `codex|<session>|<用量行 thread_id>|<原始时间戳>`，同一新键按文件内有效用量行顺序加 `#2`、`#3`，不使用 token 数；缺 thread/time 时回退规范化路径 hash＋物理行号。每条新身份的 `replaces` 均含旧响应键，首条停用旧 active 行，其余独立新增；`superseded_by` 指向首条承接记录，不表示完整的一对多关系。无响应 id 保持原位置回退。正常 id 的只读样本后缀长 35、48 或 50，16 字符阈值低于样本下限。Node golden 不重写；Rust 对拍只为明确的合成短 id `r1`、`response-local` 调整期望身份和 Codex revision，其余字段仍严格比较。回归覆盖独立子线程、完整与部分 Copied 历史、同时间序号、重复采集、追加、一对多重采集和压缩替换。真实账本执行仍需备份、副本演练及用户确认；Node 旧解析器不能用来重新采集 Rust revision 5 及以后采集的账本。

   已知限制：上游复用正常形状的长 id 时仍按旧 key 合并、原地更新，与 E1 之前的行为相同；不能据此保全复用长 id 的独立请求总数。2026-11-16 只读核查第三方中转站样本和本机日志，同一 session 与正常形状 id 对应不同原始时间戳或 usage 的情况均为 0，跨文件核查也包括在内。

   - 同一 thread、同一原始时间戳有多条不可靠请求时，日志前面的行被裁剪会使 `#n` 前移，可能覆盖旧行，造成多算。2026-11-16 用第三方中转站样本只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。
   - 同一文件里完全重复的用量行会得到 `#2`，造成多算。2026-11-16 用第三方中转站样本只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。
   - 不可靠 id 缺 `thread_id` 或原始时间戳不是字符串时，退回路径 hash 加行号，跨文件副本无法去重。2026-11-16 用第三方中转站样本只读核查：3,238 条用量行全部带 `thread_id`，68 条不可靠 id 中同 thread、同毫秒的重复为 0。

8. **请求数与会话时段归属**。桌面查询追加 `request_count`，只数 active event，纯 cumulative 分组返回 NULL。会话列表的顶层用量与请求数属于所选时段，按 `scope()` 的 `observed_at` 归属；`cumulative` 是整个会话的汇总，起止时间与 `has_cumulative` 也取整个会话。有时段按时段 gross 降序，无时段按最近活动降序。快照算在开始那天，不做按天摊分。golden 只追加这些字段，保留旧字段的值。

分组、时间桶和会话另带 `event_gross_tokens`：只加 event 的四类 token，各列先 coalesce 再相加。“平均每次”使用此值除以 `request_count`，合并模型/工具时同时合并这两个字段，快照不进入分子。会话详情的 `period` 沿用列表的时段、工具和项目筛选，`session` 的累计不受筛选影响。累计查询先分页会话身份，再用 `idx_usage_session(source, session_id)` 取对应 active 记录；无时段而带项目/模型筛选时，排序仍以整个会话的最后活动为准。开始日期 chip 使用查询快照的固定偏移，非今年的日期包含年份；首页累计与时段 gross 不同时显示累计行。

9. **E4a 桌面请求计时**。桌面 schema v6 比 Node v5 仅多 usage_timings；迁移对拍继续严格比较全部 v5 表与列，另外测试 v6 表、备份与 WAL 行数。Node goldens 不重写，适配器对拍移除已断言无首字/生成证据的附加 timing 字段（既有 Pi 夹具的整次耗时另由 E4b 测试验证）；查询对拍仅移除已断言 NULL 指标和分母正确的 timing/model_timing，其他字段仍比较。计时独立使用按 source 区分的 TIMING_REV，claude 为 3，codex、kimi、zcode、qwen、pi、openhands、anythingllm、opencode、mimo、kilo、grok、antigravity 为 1；用量 PARSER_REV 保持基线 codex=5、kimi=5、zcode=1；Node codex 仍为 4，身份差异继续遵循本节第 7 条。原有分组之和、用量和金额对拍测试保留。

D4 切换以后才考虑的修复（D3 不做）：时间桶按历史日期分别处理 DST；`pricing_snapshot` 只存 `{version}`、不能按旧版本重新估值（`write.js:481–485`）；会话详情默认粒度三处不一致（`read.js:587`、`api/v1/sessions.js:47`、`api/router.js:33`）；`ended_at` 不是 NULL 又解析不了时，这条 `cumulative` 记录既不进时间桶也不进 `unallocated`（`read.js:46–49`）。最后这一条 Rust 原样复现，并由独立的 golden 场景固定；适配器写入的 `ended_at` 只会是 ISO 时间或 NULL，现有数据碰不到。

## Rust 布局

### E4：请求与回合计时（桌面 schema v6）

D3 的 Node 对拍基线仍为 v5。桌面版增加独立的 `usage_timings`，不改 `usage_records` 的列、身份、`content_hash` 或计价。它以 `record_key` 为主键和外键，与 event 一对一；保存 source、首字、生成时长与整次调用耗时 duration_ms（整数毫秒）、各自的 method（含 duration_method）、`timing_output_tokens`、scope、status、source_file、计时版本和独立的 timing_hash；v6 的 usage_timings.parser_rev 列保留原名，但只存 TIMING_REV，与 usage_records.parser_rev 无关。计时有自己的按 source 区分的 revision：claude 为 3，codex、kimi、zcode、qwen、pi、openhands、anythingllm、opencode、mimo、kilo、grok、antigravity 为 1；值、身份或时间改变要升 PARSER_REV 的契约仅适用于用量记录，计时修正规则只升 TIMING_REV，不改用量版本、内容或价格。

- **≈首字时间**（界面名“首字（开始回复前要等）”）：发出请求至首次实际输出的等待，思考、工具参数、正文都算；元数据和 role-only 分块不算。Kimi Code、ZCode、Codex、Claude Code、Antigravity 使用 `request`；OpenCode、MiMo、Kilo 另支持推理开始事件代理，Grok 使用独立的 `turn`。Codex 仅能观察思考与回复项，工具专用输出没有首字样本。
- **≈速度**（界面名“速度（回复时每秒出多少）”）：该请求的输出 token（adapter 现有口径，含推理）除以首次输出至流结束的秒数。分子独立存成 `timing_output_tokens`；只有 `status=completed`、输出已知且生成时长大于 0 的请求进入速度统计。不设 token 门槛。
- **≈请求平均吞吐**（界面名“平均速度（算上等待）”）：1000 × Σtiming_output_tokens ÷ Σduration_ms，包含首字前的等待，与“≈速度”分开。只计 status=completed、输出已知、duration_ms>0 的样本，按 duration_method 分组，不平均逐条吞吐。duration_ms 与其他时长一起存储、hash、保留或整组替换；新接入来源差值≤0、字段无效或无法唯一配对时为 NULL。scope 只允许 request/turn，method 增加 content_event_proxy；v6 未发布，直接扩展 timings.sql，不新增 schema 版本。
- 首字按 method 分组，使用 nearest-rank：升序排列 n 个样本，分位数 p 取第 `ceil(p*n)` 个（从 1 起）；中位数 p=0.5，p90 p=0.9，偶数样本取两个中间值里较小的一个。
- 速度按 generation_method 分组，取 `1000 * Σtiming_output_tokens / Σgeneration_ms`，不平均逐条速度。不同 method 不混合。
- 三项各自返回有效样本数 n；请求级 N 是同一筛选范围内 active event 的去重请求数，包括没有计时、失败和未知状态的请求，不包括 cumulative 或 Grok 回合。Grok 的 active event 一条代表一回合，单独返回 turn.turn_count，包括无计时回合；turn 计时不进入请求的分位数、速度、吞吐或覆盖率。通用用量查询的 request_count 沿用原口径，仅计时汇总分母按 scope 拆分。每个 method 的覆盖率都是自己的 n/N。没有样本时对应 ttft、speed 或 throughput 返回 NULL，界面省略该指标并列出缺失项；N=0 不计算百分比。
- `client_reported` 表示客户端记录的计时（如 Kimi、ZCode、Antigravity），`log_timestamps` 表示以日志时间戳为基准的估算（如 Codex、Claude Code）。`content_event_proxy` 表示“按推理开始事件估算”。首字、生成时长、整次调用耗时分别带 method；缺值的 method 也为 NULL。客户端计时仍受网络、代理、分块与缓冲影响。
- status：`completed` 为请求窗口正常结束（含工具调用结束、达到输出上限）；`partial` 为有用量但仍在运行；`failed` 为已记录失败；`cancelled` 为已记录取消；`unknown` 为无法确定结束状态。后三类与 partial 不进入速度统计；已有合法首字仍可计入首字分布。Kimi 读取 finishReason，ZCode 读取 model_usage.status（error 映射 failed、running 映射 partial）；Codex 的 token_usage_record 是每次响应终结的用量记录，记 completed，中止边界清空尚未配对的计时。
- **Claude Code**。整次耗时以唯一匹配的 `api-request` 时间戳为起点。首块明确为 thinking（`apiBlockIndex=0`）并有正的 `thinkingDurationMs` 时，从首块时间戳减去该时长，再减同一个请求起点，得到首字估算。只保留大于 0 且不超过整次耗时的首字。以日志记录作为起点可能包含客户端的请求准备时间。
- **Antigravity**。客户端分别记录首字等待和后续输出时长，相加后取整毫秒作为整次耗时。后续输出不足 50 ms 时生成时长存 NULL。极短的工具调用可能使少量输出 token 得出异常高的速率。首字和整次耗时仍按各自有效值记录。已识别字段无法确认结束状态，记 `unknown`，可纳入首字分布。

查询通过 usage_records join 计时，继承 active、时段、工具、项目、模型与会话筛选。会话详情的 timing 使用 period 筛选；明细 source/model/source_model 分组保持同一过滤口径。breakdown 和 session_detail 各在一个读取事务里计算用量与计时。`source_model` 另外返回每个模型在当前筛选下的 `model_timing`，供界面合并工具分组时使用，不能由各工具的中位数推导模型中位数。首页不展示计时。

工具/模型明细把计时放在对应主行下方的可换行指标区，左侧标“每次请求”；至少一项有样本才显示请求计时行。turn_count > 0 时另加同样样式的“每轮对话”行。主行与计时行共用点击、悬停和卡片内的墨水边界，宽屏分隔线在整个行组下方。宽屏表格沿用 860 最小宽度，不增加计时列；工具/模型表格可用宽度不足 860 时使用窄屏行布局，不横向滚动。不显示计时的维度保持原布局。模型行的工具图标最多显示 3 个，多出的用“+N”标记，悬停列出全部工具名；模型名保留可见宽度，单行省略并提供全名悬停提示，窄屏同样处理。会话详情使用标题为“每次请求”“每轮对话”的独立卡片；Grok 即使当前时段没有样本也保留回合卡片，纯回合会话不展示请求卡片。

计时区共用文案和缺失提示。首字显示“一般 x.xx 秒，慢时 y.yy 秒”，只有一个样本或两分位数相同时仅显示“x.xx 秒”；速度和平均速度显示“约 x.x token/s”。每项默认只显示标签、“?”和一个数值；有多个 method 时主值取 `client_reported`，没有就取第一个，后面用淡色小字写“· 另有 N 种估算”。数值的浮层在鼠标停留约 250 ms 或 Tab 聚焦时出现，悬停时数值有淡色虚线下划线；浮层按 method 分组列出数值，多个 method 时数值后接来源名，下一行淡色字为“{N} 次请求里 {n} 次有记录”，只有一个 method 时后接来源名，n=N 时省略覆盖率只写来源名。N 与 n 沿用请求列的千位分隔格式。无样本的指标不显示；“日志里没记：首字、速度、平均速度”中的缺失项放进行标签的浮层，接在行标签说明下面，行标签同样可以 Tab 聚焦。浮层内容同时作为读屏说明。首字的小“?”说明为“从发出请求到看到第一段输出（含思考）的时间。‘一般’是一半请求不超过这个时间，‘慢时’是九成请求不超过这个时间。”其余指标的小“?”说明输出速度和包含等待的平均速度；行标签说明日志推算的约值及整轮对话与每次请求不能直接比较。多个 method 在数值浮层里独立展示。

跨文件副本先按现有 settle 规则选定 usage 的归属，计时随同被保留的记录写入；不能用副本的计时补齐原件。计时按整组保留或替换，不逐指标拼接：本次用量新增或 content_hash 改变并原地更新时，计时整组换成本次解析结果，缺少 timing 对象则删除旧计时，不能沿用与当前用量不匹配的窗口和输出分子；只有本次用量 content_hash 与原来相同，才适用以下保留规则：source_file 和 TIMING_REV 都相同时，旧组 status=completed 就整组保留，不论新组是否缺值或为超集，避免日志裁剪缩短已完成窗口；只有旧组不是 completed，且新组为旧计时已知指标的超集（旧的每个非 NULL 时长（ttft_ms、generation_ms、duration_ms）在新值中也非 NULL）时，才整组替换，支持 ZCode 从 partial 增长到 completed；否则整组保留。status、timing_output_tokens、三个 method 和 scope 随整组决定，不从另一组补齐；选择后再计算 timing_hash，重复采集不反复更新。source_file 或 TIMING_REV 变化时整组替换，包括撤销，不能继承旧归属文件的计时；文件成功重解析后，新 TIMING_REV 不再产出的旧计时会清除，即使空产出保护仍保留历史用量。文件没有被发现或读取失败不清除计时。TIMING_REV 是文件缓存指纹的一部分（见下文 E5），版本改变的来源会重新解析全部文件，无需额外触发；只清除旧计时，不停用用量，用量因自身版本升级或 replaces 停用时仍删除其计时。

**v6 迁移与回退**：先沿用原流程把 v1–v4 升到 v5；已有磁盘账本在升 v6 前用 `VACUUM INTO` 生成一致的 v5 备份，包含已提交 WAL 内容，不能直接复制在线主文件。文件名为 `ledger-v5-YYYY-MM-DD-<毫秒时间>-<序号>.db`，位于账本所在数据目录，已有文件不覆盖；备份失败不创建 v6 表。新建空账本和内存测试库不需要旧库备份。随后在事务里建表并设置 user_version=6。旧版桌面应用拒绝打开 v6；恢复 v5 备份的步骤见 app/README.md。Node 回退目录 `~/.token-lens` 不受影响。

### E5：同步分段计时与文件缓存（桌面 schema v7）

**分段计时**：每次成功的同步在运行日志的 `end` 行后写一行 `phases {…}`，记录发现、读取、解压、文本解析、SQLite 来源读取加解析、settle、写入、缓存读写、重新计价和收尾各段的纳秒耗时，以及文件数、字节数、写入事务数、`parsedFiles`/`cachedFiles`/`skippedFiles` 和各来源耗时。这一行只含数字和来源名，不含路径或日志内容。`app/rust/examples/sync_bench.rs` 用固定种子生成合成日志，测冷同步和文件不变的重同步，并导出规范化快照的 SHA-256（去掉自增 id 和导入时间，`superseded_by` 换成记录键）；后续改动以快照哈希不变证明结果不变。

**写入路径**：批处理里的常用语句使用连接的预编译语句缓存；当前记录没有计时且确认没有旧计时行时不发 DELETE。每个文件结束时的计时版本撤销查询（按 source_file 和 TIMING_REV 筛 `usage_timings`）只在该文件可能有旧版本计时时执行：账本连接在内存里记下每个文件已有的计时版本，在写事务里读取，用 `PRAGMA data_version` 和 `total_changes` 识别两次文件事务之间其他连接或本连接的修改，一旦不一致就重新读取；只在事务提交成功后保存，出错或取消时丢弃。每个文件仍是一个事务。

**文件缓存**：v7 在 `ledger.db` 里增加四张表，不改 `usage_records`、`usage_timings` 和 `ingest_runs` 的列：

| 表 | 内容 |
| --- | --- |
| `ingest_files` | 主键 `(source, path)`。`fingerprint` 是命中条件的编码；`payload` 是该文件上一次完整解析的输出：无效时间过滤之后、settle 之前的有序记录（保留 NULL、文件内重复身份、`replaces` 和完整 timing 对象）以及适配器 notes。不存日志原文。 |
| `ingest_file_replaces` | 主键 `(source, path, target)`，缓存记录里非空且不指向自身的 `replaces` 目标，随对应文件的缓存级联删除。 |
| `ingest_pending_sources` | 一个来源开始逐文件提交前写入，整个来源处理完后清除；进程中断后，即使剩余文件全部命中，下一轮也按原顺序重新处理这个来源。 |
| `ingest_run_files` | 主键 `run_id`（关联 `ingest_runs.id`），记录该次运行的 `parsed_files`、`cached_files`、`skipped_files`，与运行结果一起提交。 |

命中要求以下各项都与缓存一致：文件身份路径、大小、系统给出的最高精度修改时间、全部旁文件的路径和状态（含“不存在”）、该来源的 `PARSER_REV` 和 `TIMING_REV`、解析时区身份、缓存格式版本（当前为 1）。有任何一项缺失或不同就重新解析。旁文件：Grok 与 `updates.jsonl` 同级的 `summary.json`；Cline（含 Roo）与 `api_conversation_history.json` 同级的 `ui_messages.json`；CodeBuddy 桌面 JSON 主文件上两级目录的 `index.json`；OpenHands `base_state.json` 同级 `events/` 下按适配器规则匹配的事件文件（按文件名排序）。时区身份在 Windows 上取系统动态时区 ID、偏差和夏令时规则，其他平台取系统时区身份和本机时区规则文件的状态；时区变化让全部普通文件的缓存失效。

SQLite 来源（hermes、cursor 数据库、opencode、kilo、goose、zed、copilot、mimo、minimax、zcode、anythingllm、antigravity）不缓存，每轮照常读取、settle 和写入，因为已提交数据可能只在 WAL 里。Copilot 的 `session-store.db` 和 Antigravity 的 `conversation_summaries.db` 同样每轮实时读取。Cursor 的 CSV 是普通文件，参与缓存。

按来源处理：

- 来源的发现文件集合与上次相同、每个文件都命中、没有待处理标记，且缓存里没有 `replaces` 指向账本中仍然有效的行时，跳过该来源的 settle 和全部账本写入。最后一条防止“同一文件里替换记录排在被替换记录前面”这种要两轮才收敛的情况在第二轮被跳过；这种情况下第二轮用缓存结果重新处理一次，结果与不用缓存逐轮一致。
- 来源有任何变化时，命中的文件加载缓存结果，未命中的重新解析，然后对整个来源照原样 settle，并对每个文件照原样写入。文件缓存行与该文件的用量、计时在同一事务提交；取消或出错时一起回滚，下一轮补上。
- 解析前后各取一次指纹，不一致时本轮照常使用解析结果但不写缓存，下轮重新解析。无法反序列化的缓存在需要时回源重读。
- 读取失败计入 `read_failed`，排除出 settle，不发 batch，并让该文件的缓存失效。退出发现集合的文件删除缓存；账本里的历史用量照原规则保留（vanished）。
- 价格变化不让缓存失效；全部来源都跳过时仍照常重新计价。

**快速模式的已知限制**：大小和修改时间都不变、内容却变了的文件，缓存发现不了。此时用“重新读取全部日志”（`reread`）：它不看缓存，重新解析每个候选文件，对全部来源照原样写入并重建缓存。它不清空账本，vanished 保留等规则照旧。

**同步结果**：`sync` 返回和 `StatsSync` 保留原字段，并新增 `parsedFiles`（本轮交给适配器解析的文件数，含 SQLite 和读取失败项）、`cachedFiles`（本轮处理的来源里沿用缓存的文件数）、`skippedFiles`（整个来源被跳过的文件数）。`fileCount` 仍是发现的文件总数。`attempted`、`inserted`、`updated`、`unchanged`、`rejected` 和 `counts` 只统计本轮实际处理的部分，被跳过的来源计 0。与 Node 对拍的 golden 用 `reread` 路径运行；缓存路径由缓存、重读、基线三方逐步对拍和单元测试覆盖。

**v7 迁移与回退**：已有磁盘账本升 v7 前，用单独的只读连接 `VACUUM INTO` 生成一致的 v6 备份 `ledger-v6-YYYY-MM-DD-<毫秒时间>-<序号>.db`（同目录，不覆盖已有文件），再在一个事务里建上述四张表并设 user_version=7，提交后写一行 `migration schema=6->7`。v6 的桌面程序拒绝打开 v7；恢复方法与 v5 备份相同，见 app/README.md。升级后第一轮同步全部未命中，等同一次完整读取。

统计代码放在 `app/rust/src/stats/`，和新闻代码互不依赖：

| 模块 | 职责 | 对应旧版 |
| --- | --- | --- |
| `jscompat` | JS 数字转字符串、`Date` 宽容解析、JSON 键序、`localeCompare`、`encodeURIComponent` | 散在各处 |
| `ledger/open` | 打开、PRAGMA、v1→v7 迁移、v5 与 v6 一致备份、拒绝更高版本 | `db/open.js` |
| `ledger/write` | 入库分支、文件停用、`ingest_runs`、重新计价、legacy 导入 | `db/write.js` |
| `ledger/read` | 聚合、分组、时间桶、会话、来源、价格标记 | `db/read.js` |
| `pricing` | 价表数据、规范化、分档、峰谷、计价、显示用舍入 | `pricing/*.js` |
| `lock` | `sync-lock.db` 协议 | `sync-lock.js` |
| `discovery` | 27 个来源的扫描根和模式 | `discovery.js` |
| `adapters/<source>` | 每个客户端一个文件，加共用的 `lines`、`num`、`project`、`zstd` | `adapters/*.js` |
| `ingest` | 发现 → 指纹比对（命中的文件读缓存）→ 解析 → 跨文件副本 → 入库与缓存同事务 → 重新计价；分段计时 | `ingest.js` |
| `ingest_fingerprint`、`ledger/ingest_cache` | 文件缓存的指纹（大小、修改时间、旁文件、版本、时区）、v7 缓存表与迁移 | 无（桌面新增） |
| `service` | 各接口的参数、默认值、格式化 | `api/v1/*.js` |

价表在 D3 期间有两份，JS 和 Rust 各一份。Rust 的单元测试固定 `PRICE_VERSION` 必须等于旧版的值；D4 之前改价必须两边一起改，测试会拦住只改了一边的情况。

### 逐次请求列表

`StatsClient::requests(filter, query, offset_minutes)` 从 `usage_records` 中读取 `kind='event'`、`active=1` 的行，LEFT JOIN `usage_timings`。`id` 是列表使用的 `record_key`；四项 token 与金额保留 NULL，不根据其他字段补零或重新计价。只记录 cumulative 总数的工具没有逐次请求，不进入列表。在相同筛选下，列表全部行的四项 token 分别等于事件部分的对应项，其和等于 `event_gross_tokens`，请求总数等于 `request_count`（没有事件时列表 total 为 0，汇总 request_count 可以是 NULL）。混合 cumulative 的筛选只对账事件部分。

筛选复用账本的 `scope()` 和本地时区偏移。请求 FFI 支持时段、工具、模型、项目及月、日、小时桶；明细页请求列表与页面总计共用时间范围：月、日桶与当前时段取交集，小时桶沿用页面总计的时段范围，不单独限制到那一小时。`query.source` 与 `query.session_id` 必须同时提供；提供后按这对身份读取会话全部事件，忽略时段、桶、工具、模型、项目筛选。总数、门槛和当前页在一个读事务中取得，响应附带既有格式的 snapshot。

- `ttft_ms` 有记录就返回，不受 status 限制。
- `speed_tps = timing_output_tokens × 1000 / generation_ms`，只在 completed、generation_ms > 0 且 timing_output_tokens 非 NULL 时返回。
- `throughput_tps` 同样要求 completed、duration_ms > 0 且有 timing_output_tokens，分母为 duration_ms，包含等待时间。
- 排序字段为 time、cost、ttft、speed；speed 优先用生成速度，没有时用平均速度。NULL 在升降序中都排末；并列时按 observed_at 降序、record_key 升序，排序与分页在 SQL 中完成。
- 慢门槛取整份筛选或整段会话中的 request 样本，使用 nearest rank：`sorted[ceil(p·n)−1]`。首字取 p90，值大于等于门槛标慢；生成速度升序取 p10，值小于等于门槛标慢。两项分别至少需要 10 个有效样本，否则门槛为 NULL。turn、平均速度不参与也不标慢；timed_only 不改变门槛样本。

第一页传 `include_summary=true`，返回 total 和 slow。后续页传 false，两项返回 NULL，界面沿用第一页摘要。每页 30 条；换筛选、排序或计时勾选项均重取第一页。在“按请求”中选择工具、模型或项目保留请求维度、当前排序和计时勾选状态。`timed_only` 只保留首字、生成速度、平均速度中至少一项非 NULL 的请求。分页期间采集改变账本时，界面随账本版本重取第一页；不同调用之间不持有数据库快照。

明细页“拆开看”提供“按请求”（地址 `dim=request`），宽布局显示时间、工具、模型、金额、四项 token、首字、速度；沿用明细页 860 的可用宽度判断，空间不足时使用两行排版和同款筛选式排序下拉，不横向滚动；工具名先占足宽度，长模型名单行省略并提供完整名称悬停。时间、金额、首字首次选择为降序，速度首次选择为升序，再选当前字段切换方向；宽窄布局共用状态。有会话编号的行支持鼠标点击和键盘回车，跳到 source/session 指定的会话，键盘焦点使用陶土色描边。没有会话编号的请求照常列出并计入合计，行不可点击或聚焦，不显示可点悬停效果，并提示“这次请求的日志里没有会话编号，打不开所在的会话。”。

会话详情仅在 kinds.event > 0 时显示“概况 / 请求”，默认概况并保留原有内容。“请求”始终用两行排版，第一行显示时间、模型、金额；第二行和明细紧凑行一样，token 四项与“首字 / 速度”分成两组，计时组放不下时整组换行，组内按完整项目换行。排序使用紧凑胶囊。列表不受会话页时段筛选影响，行不可点击。两处列表的“—”统一使用浅色常规字重，分页剩余数与总数均使用千位分隔。

两处共用数字格式、分页、缺失提示与慢门槛。token 沿用设置中的单位和精确值悬停提示，NULL 显示“—”；金额使用货币设置与汇率，三位小数，正数不足 0.001 时显示如 `<$0.001` 的金额，无价格显示“未定价”。首字为秒，速度保留一位小数；只有平均速度时显示小号“≈”及包含等待的说明。慢值使用警示褐色，并提供“比这里九成请求都慢”的悬停提示；turn 值提供整轮计时说明。缺失首字区分 Codex 从工具调用开始和日志未记录，缺失速度区分请求未正常结束和日志未记录生成时长。加载、出错及重试复用明细资源组件。

## 数据目录与采集

- 统计账本：`<预览目录>/ledger.db`，锁文件是同目录的 `sync-lock.db`。预览目录沿用新闻用的规则（`TOKEN_LENS_PREVIEW_DATA_DIR` 或应用支持目录），D3 不读旧版的数据目录变量。
- 日志根目录：默认取系统用户目录，`APPDATA`、`LOCALAPPDATA`、`XDG_DATA_HOME` 和各客户端自己的覆盖变量按旧版规则读取。为了测试和对拍，可以用 `TOKEN_LENS_PREVIEW_HOME`（FFI 的 `logsHome`）指向别的根目录；这时所有发现路径都从这个根推出，上述变量一律忽略，预览扫描也不跟随指向根外的符号链接和 Windows reparse point（`discovery.rs` 的 `Environment::preview`、`Scan::allowed`）。测试一律使用合成的根目录。
- 发现问题：目录不存在时安静跳过；目录存在但打不开时，按来源记 `permission_denied`（拒绝访问）或 `io_errors`（其他 I/O 错误）；目录项读不了时记 `unreadable_entries`，其余目录项照常扫描。`StatsDiscovery` 和 `StatsSources` 新增可选字段 `discovery_issues`（每项含 `source` 和这三个计数）。同步把它们存进现有 `ingest_runs.counts`，键为 `discovery.<source>.<kind>`，不改表结构；旧运行记录没有这些键时读作空列表。
- 采集时机照旧：窗口打开后采集一次，开着时每 5 分钟一次，另有手动同步；撞上锁就跳过这一次。来源页另有“重新读取全部日志”（trigger 记为 `reread`），走同一套冲突、重试和刷新路径，只是不看文件缓存。关窗就停止采集，进行中的事务回滚，已经提交的文件保留。
- 读取客户端日志只读；外部 SQLite 不做 checkpoint，也不加 `immutable`。

## FFI

`StatsClient` 对应旧版看板在用的接口，参数和字段名沿用 `/api/v1`（[api-v1.md](../archive/api-v1.md)），只是改成类型化的结构，不再经过 HTTP：

| 方法 | 旧接口 | 用到它的界面 |
| --- | --- | --- |
| `summary` | `/usage/summary` | 总览、明细、引导 |
| `timeseries` | `/usage/timeseries` | 总览、明细 |
| `matrix` | `/usage/matrix` | 总览、明细 |
| `breakdown` | `/usage/breakdown` | 总览、明细、来源、设置、会话 |
| `sessions`、`session_detail` | `/sessions`、`/sessions/detail` | 总览、会话 |
| `query_sessions` | 桌面扩展 | 会话的搜索、排序和分页 |
| `comparison` | 桌面扩展 | 总览、归因面板、明细对比 |
| `session_detail_in_period` | 桌面扩展 | 会话详情的时段汇总；`period` 使用同一 `StatsFilter`，`session` 与 day timeline 保留整个会话 |
| `requests` | 桌面扩展 | 明细“按请求”、会话详情“请求”；第一页返回摘要，后续页只返回列表与 snapshot |
| `sources` | `/sources` | 总览、来源、会话 |
| `discovery` | `/discovery` | 引导 |
| `pricing` | `/pricing` | 总览、设置 |
| `health` | `/health` | 设置 |
| `sync` | `POST /sync` | 引导、来源、定时采集 |
| `sync_triggered("reread")` | 桌面扩展 | 来源页“重新读取全部日志”；不看文件缓存，返回与 `sync` 相同的结构 |

- 金额在 FFI 上用整数 micro-USD 传递，界面显示用的六位小数字符串和低精度最大余数分配由 Rust `pricing` 统一给出。账本金额只用 Rust 的值，Dart 不重新计价；旧前端自己做的展示推导（按工具合计、比例、环比、币种换算、“缓存帮你省了”的估算）照旧版在 Dart 里做。
- 时区：Dart 传当前的 UTC 偏移分钟数，Rust 用它切所有历史，和旧版一致。快照里的时区名先读 `TZ`，没有再调用系统自带的 ICU（Windows `icu.dll`、macOS `libicucore`），不打包 ICU；macOS 上的链接和运行还没验证。
- 不迁移：`/usage/unallocated`（看板没用，`timeseries` 已含）、`POST /pricing/refresh`（旧版就是 501）、HTTP 边界（gate、token、port）及其响应缓存、CLI、只有测试在用的 `modelStatus` 和 `priceVersions`。
- 并发：同一时间只有一个采集在跑；查询可以和采集并发，读的是已提交的数据。

- `StatsDiscovery.tools` 给出当前系统的候选目录、文件数和状态。目录状态包括 `found`、`missing`、`permission_denied`、`io_error`。工具合并状态优先显示找到，其次是权限问题、读取错误、缺失。绝对路径只通过桌面 FFI 返回。
- `StatsFilter.excludeSources` 传入来源 ID 后，在账本查询的公共筛选中排除这些来源。省略或传空数组时沿用原有查询和响应。逐次请求的会话范围和会话详情同样受此条件约束。
- `query_sessions` 使用公共筛选确定会话集合，再按不分大小写的子串匹配会话 ID、显示工具名和该会话的项目路径与模型。会话聚合在 Rust 侧排序，金额 NULL 在两个方向均排最后，并列按会话 ID、来源 ID。游标沿用十进制 offset 的 Base64 编码，页面在筛选、排序或账本版本变化时回到第一页。未提供新参数时沿用旧的默认排序和输出。
- `comparison` 在同一 SQLite 读事务内读取两个 `StatsFilter` 各自的汇总和指定维度分组，支持项目、工具和模型。缺失分组键为 NULL，贡献照常计入该边汇总。`StatsFilter.missing` 让归因中的空项目或空模型也可在明细中筛选。金额以已计价部分的整数微美元相减，保持分组差额之和等于两边汇总的差额。
- `StatsClient.syncProgress()` 提供内存快照，字段包括阶段、工具 ID、工具序号与总数、已读取文件数和触发方式。已读文件数统计实际交给解析器的文件。Flutter 只在同步期间约每 300 ms 读取一次。Rust 在同步退出时清空快照。

## 对拍

旧版删除后（标签 `legacy-node`），生成器 `scripts/parity/` 随之删除，`app/rust/tests/golden/` 和 `app/rust/tests/fixtures/` 冻结，不再重新生成。下面记录生成时的做法。

- 生成器 `scripts/parity/` 调用旧版的生产入口（`adapters[source]`、`payloadHash`、`fileTag`、`Ledger`、`read`、各个 service），固定 `now`、时区和路径字符串，输出 UTF-8 JSONL。每行的 `type` 是 `adapter_record`、`identity`、`batch`、`ledger_row`、`price`、`query`、`run` 之一，字段顺序固定，NULL 显式写出。
- 夹具：现有的真实裁剪样本（codex、qwen、pi），加上把各测试里内联构造的合成输入整理成的静态文件，放在 `app/rust/tests/fixtures/`。
- 旧版输出提交到 `app/rust/tests/golden/`。Rust 测试读同一批夹具，输出同样的 JSONL 并逐行比较；身份和金额按字节比较，没有确定顺序的查询先按身份排序再比较结构。
- 时钟：旧版直接读 `Date` 和 SQLite `unixepoch()`，没有注入点。生成器用 Node 内置 `node:test` 的 `mock.timers` 只冻结 `Date`（固定 `2026-01-15T12:00:00.000Z`；主时区 `Asia/Shanghai`，另有 UTC，Date 兼容表还含 `America/New_York`），这是生成器里唯一允许的替换，不改 `src/core`。Rust 凡是读当前时间的地方都经可注入的时钟。
- 只有四个字段写成 `"<volatile>"` 不比较：`usage_records.ingested_at`、`legacy_records.imported_at`、`pricing_snapshot.created_at`（SQLite 默认值）和 `runIngestion` 的 `durationMs`。`snapshot.generated_at`、`ingest_runs.started_at` / `finished_at`、滚动 7/30 日、`pricing_snapshot.verified_at` 由冻结的时刻决定，严格比较。
- Rust 的行为需要与旧版不同时，不改 golden 文件：在测试里显式处理这处差异，并写进上文「允许的差异」。

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
