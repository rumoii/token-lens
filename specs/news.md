# AI 热点

## 阶段与联网边界

桌面预览共接入 20 个来源：D2 多来源契约中的 16 个基础来源、「D2.5 开发者变更」中的 3 个来源，以及 D2.6 增加的 `aihot`。Rust 是来源访问和缓存的唯一所有者；Flutter 通过生成的 FFI 调用，不发送来源请求。预览不读取客户端日志或统计账本，统计功能继续使用原有版本。

启动先读取缓存。程序开着时按「D2.6 定时刷新」自动刷新已启用来源，用户也可以随时手动刷新全部或单个来源。失败后只在「D2.6 定时刷新」写明的首次失败时提前重试。没有后台补抓、追踪像素或远程图片。打开原文需用户点击，交给系统浏览器。搜索、分类和来源筛选只处理本地快照。

D2.5 增加 3 个来源和条目类型，见「D2.5 开发者变更」。Anthropic 官网新闻、Qwen、机器之心、arXiv、Reddit 待后续接入；X 和 Discord 不接入。Claude Code 的 GitHub 版本更新不等同于 Anthropic 官网动态。

## D2 多来源契约

### 来源注册

每个来源是一次刷新里的一个请求单元，带稳定 `id`、显示名、分类和主页。分类为 `official`、`tools`、`community`、`chinese`。同分类的优先级与无日期条目的顺序使用下表注册顺序。

| id | 名称 | 分类 | 固定请求 |
| --- | --- | --- | --- |
| `openai` | OpenAI | official | `https://openai.com/news/rss.xml` |
| `deepmind` | Google DeepMind | official | `https://deepmind.google/blog/rss.xml` |
| `google-ai` | Google AI | official | `https://blog.google/innovation-and-ai/technology/ai/rss/` |
| `deepseek` | DeepSeek | official | `https://api-docs.deepseek.com/news/news261017/` |
| `gh-release:anthropics/claude-code` | Claude Code | tools | `https://api.github.com/repos/anthropics/claude-code/releases?per_page=20` |
| `gh-release:openai/codex` | Codex | tools | `https://api.github.com/repos/openai/codex/releases?per_page=20` |
| `gh-release:google-gemini/gemini-cli` | Gemini CLI | tools | `https://api.github.com/repos/google-gemini/gemini-cli/releases?per_page=20` |
| `gh-release:anomalyco/opencode` | OpenCode | tools | `https://api.github.com/repos/anomalyco/opencode/releases?per_page=20` |
| `gh-release:earendil-works/pi` | Pi | tools | `https://api.github.com/repos/earendil-works/pi/releases?per_page=20` |
| `gh-release:ollama/ollama` | Ollama | tools | `https://api.github.com/repos/ollama/ollama/releases?per_page=20` |
| `github-new` | GitHub 新项目 | community | GitHub Search，最近 7 天创建，按 stars 降序，`per_page=30` |
| `hf-models` | Hugging Face 模型 | community | `https://huggingface.co/api/models?sort=trendingScore&limit=30` |
| `hf-spaces` | Hugging Face Spaces | community | `https://huggingface.co/api/spaces?sort=trendingScore&limit=30` |
| `hf-papers` | Hugging Face 论文 | community | `https://huggingface.co/api/daily_papers?limit=30` |
| `hn-ai` | Hacker News | community | `https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=100` |
| `qbitai` | 量子位 | chinese | `https://www.qbitai.com/feed` |

地址与字段于 2026-11-05/06 核实。Google AI 旧地址 `/technology/ai/rss/` 会重定向，直接使用表中的新地址。DeepSeek 采用文章页共享的服务端侧边栏取得新闻列表；URL 保留尾斜杠，避免 302。OpenCode 与 Pi 的仓库分别为 `anomalyco/opencode`、`earendil-works/pi`。

GitHub 新项目请求 `https://api.github.com/search/repositories`，查询为 `created:>=<UTC 日期> topic:llm,ai-agent,generative-ai,machine-learning`，日期取 `now_ms` 的 UTC 日期减七天，参数 `sort=stars&order=desc&per_page=30`。逗号 topic 表示任一 topic；qualifier 之间不使用 API 不支持的 `OR`。Releases 只保留非 draft、非 prerelease，并按可配置的 `tag_name` 前缀过滤：Codex 为 `rust-v`，OpenCode 为 `v`（排除 `process-daemon-v` 等子包）；Claude Code、Gemini CLI、Pi、Ollama 的已核实样本未见子包噪音，不设前缀。OpenCode 与 Gemini CLI 的当前响应，以及其他仓库的 D2B 夹具或此前桌面缓存，构成这次核实依据；不代表完整历史 tag 保证。

Hacker News 仅在本地按标题、不区分大小写和词边界筛选：`ai`、`llm`、`llms`、`gpt`、`claude`、`gemini`、`openai`、`anthropic`、`agent`、`agents`、`model`、`models`、`deepseek`、`llama`、`qwen`、`mistral`、`transformer`、`inference`、`rag`。

Hugging Face 实际字段：models 用 `id`、`createdAt`、`pipeline_tag`、`likes`；`pipeline_tag` 缺失时描述为空。Spaces 列表不返回 `cardData`，实际标题回退 `id`、描述为空；若响应提供 `cardData.title` / `cardData.short_description` 则采用。论文用 `paper.id`、`paper.title`、`paper.summary`、`paper.upvotes`；日期优先取顶层 `publishedAt`（入选 Daily Papers 的时间），缺失或不可解析时回退 `paper.publishedAt`（论文发布日期）。

### 请求和条目处理

每个来源只请求一个 URL。连接超时 10 秒；连接后连续 20 秒收不到数据报 `timeout`；单个请求最长 60 秒，超过也报 `timeout`。响应默认上限 4 MiB；GitHub Releases 例外为 16 MiB，因为响应包含大量 release assets 元数据，Codex 的 20 条响应可能超过 4 MiB。`Source::max_body_bytes()` 声明来源上限，框架同时检查 Content-Length 和流式累计字节数；gzip 响应由 reqwest 协商并自动解压，解压后不保留压缩体的 Content-Length，流式上限按解压后的字节计算；GitHub 新项目与其他来源仍为 4 MiB。不跟随重定向，不自动重试。固定 User-Agent 为 `TokenLens-News/0.1`，不手动设置 Accept-Encoding，由 reqwest 协商 gzip。有 Content-Type 时，框架在解析前检查 `accepts()` 中的前缀；保留对缺少该 header 的兼容。

HTTP 429 和 GitHub 来源带 `x-ratelimit-remaining: 0` 的 HTTP 403 报 `rate_limited`；其他非 200 报 `http`。网络失败、超时、正文解析失败分别报 `network`、`timeout`、`parse`；超过来源上限报 `too_large`，Content-Type 不受来源支持报 `content_type`。200 HTML 不能当作成功 RSS。未登录 GitHub API 每小时限 60 次，一次全量刷新使用 7 次 GitHub 请求。

标题和短描述转换为纯文本：RSS 和 DeepSeek 的 HTML 文本去标签、解码实体；GitHub Releases、GitHub 新项目、HF 三个来源和 HN 的纯文本不解析标签、不解码实体，保留 `Vec<String>` 和 `<script>` 等字面量。两类文本均合并空白、移除控制字符并截断；标题最多 512 字符，描述最多 4000 字符。GitHub Releases 的描述先移除 Markdown 标题行（1–6 个 `#` 后接空格或行尾）、列表符号、成对的粗体标记和反引号，链接只留文字，删除裸 URL，合并空白后最多保留 300 字符；`#123 fix leak` 等非标题行保留，清理后为空则为 `None`。不渲染 HTML，只保留无凭据的 HTTP(S) 原文链接。没有描述就留空，不调用模型生成。除 `aihot` 外不读取来源的 AI 摘要字段；`aihot` 的描述本身就是 AIHOT 生成的摘要，条目标 `ai_summary = true`，界面必须标明。

### Rust 内部接口

`app/rust/src/sources/mod.rs` 定义 `Source` trait。来源只拼 URL、解析响应体，不做 I/O、不读时钟；时间窗口通过 `now_ms` 传入。框架负责请求限制、Content-Type、纯文本化、URL 校验、id、去重、缓存和状态。RSS 模块支持 RSS 2.0 与 Atom。

- `text_is_html()` 默认返回 `true`，表示标题和描述含 HTML，需要去标签和解码实体。GitHub Releases、GitHub 新项目、HF 三个来源和 HN 覆盖为 `false`，框架只合并空白、移除控制字符并按原上限截断，不把纯文本当 HTML 解析。
- `parse` 返回 `Ok(空列表)` 表示来源确实没有内容；结构变化、必需字段全缺或所有条目无效返回 `ParseError`，不覆盖旧缓存。
- `native_id` 在来源内唯一，取 guid、release id、链接等稳定值。条目 id 为 `<source_id>:<native_id>`。
- `published_at` 为 RFC 3339 UTC；缺失或无法解析时为 `None`，不猜测。
- `popularity` 只保留平台原生整数：HN points、GitHub stars、HF likes 或 upvotes，不跨平台换算。

### FFI 与状态

`NewsClient` 为不透明 Rust 对象，构造必须提供绝对数据目录，构造不联网。文件和锁操作在 Rust 工作线程执行；Flutter 等待 Future，不阻塞 UI。

- `NewsSnapshot`：`sources: Vec<SourceState>`、`items: Vec<NewsItem>`、`refreshing: bool`、`error: Option<NewsError>`。顶层错误只放 busy、closed、cache。
- `SourceState`：`id`、`name`、`category`、`home_url`、`enabled`、`refreshing`、`last_success_ms`（可空 UTC epoch milliseconds）、`error`（可空，本会话最近一次失败）。
- `NewsItem`：`id`、`source_id`、`title`、`url`、可空 `published_at`、可空 `description`、可空 `popularity_kind`（points/stars/likes/upvotes）、可空整数 `popularity`、`also_in: Vec<String>`。
- `NewsError`：稳定 `kind` 和安全 `message`；类别为 `busy`、`closed`、`cache`、`cancelled`、`network`、`timeout`、`rate_limited`、`http`、`parse`、`too_large`、`content_type`。Flutter 按类别显示中文，不展示底层完整响应。
- `snapshot()`：只读状态。
- `refresh(source_ids: Option<Vec<String>>)`：`None` 刷新全部已启用来源；显式列表忽略未知、重复或已停用 id，空列表不发请求。最多 4 个来源并发，排队来源发请求前再次检查启用状态。单来源失败不影响其他来源，每来源完成后单独原子提交。
- `set_source_enabled(id, enabled)`：持久化启停并返回快照；停用来源不发新请求，其条目从快照隐藏，缓存保留。
- `cancel_refresh()`：取消未完成来源，保留此前提交；`shutdown()` 幂等关闭，禁止新请求、取消当前刷新并释放目录锁。

刷新为 idle → refreshing → success/failed/cancelled，重复刷新返回 busy。提交、取消和关闭在同一 Rust 状态锁下裁决；取消或关闭的代次不能再提交。丢弃刷新 Future 也会取消所属工作。活动刷新返回前收拢请求任务，进程退出不留下工作进程。

`new_for_local_test(data_dir, endpoints)` 供真实桥接的离线测试使用，只接受 HTTP 数字 loopback 地址，构造不请求。桌面入口使用 `new(data_dir)` 和固定注册表，不调用测试构造入口。

### 去重与排序

来源内按 `native_id` 去重。快照跨来源按规范化 URL 去重：小写 scheme 和 host，去 fragment、`utm_*` 参数和末尾 `/`。优先级为 official、chinese、tools、community，同分类按注册顺序；`aihot` 不论分类，始终排在所有来源之后，因此同一链接有原始来源时，以原始来源为主项，`aihot` 进 `also_in`。保留主项，将其他来源 id 写入 `also_in`。合并只发生在快照中，不改各来源缓存。

`items` 按 `published_at` 降序；无日期在最后，同日期或无日期按注册顺序。每来源最多缓存 50 条。成功刷新用本次结果整体替换该来源的缓存（`Ok` 空列表即该来源确实无内容）；失败和取消保留旧缓存；刷新进行中界面保留已有内容。

### 缓存 v2 与隔离目录

每目录以 `news.lock` 独占，拒绝第二个写入者。`news-cache.json` 格式为 `{"version":2,"sources":{<id>:{"items":[...],"last_success_ms":n}},"disabled":[<id>...]}`。来源错误不写缓存，缓存不包含凭据、客户端日志、用量或账本数据。

读取 v1 时将条目迁到 `openai`，id 增加 `openai:` 前缀；仅在内存迁移，下次成功提交时写成 v2。未知版本或损坏缓存显式报 cache，不静默当作空结果。成功提交先写同目录临时文件并同步，再原子替换；失败和取消保留旧缓存。v2 不承诺供旧版 D1 读取。

默认使用系统应用支持目录中的独立 `news-preview`。开发和测试必须设置绝对 `TOKEN_LENS_PREVIEW_DATA_DIR`，不得指向真实 home、统计账本或安装版数据。`TOKEN_LENS_DATA_DIR` 与 `DB_PATH` 不参与预览目录选择。预览不迁移或写入真实账本。

### Flutter

D2.6 起由「D2.6 界面」取代。

## D2.5 开发者变更

D2.5 在 D2 契约上增加官方 API 变更来源、中文日报来源、条目类型和来源内热度排序。除下面写明的变化外，D2 的联网边界、请求限制、缓存、FFI 生命周期和错误类别不变。

### 新来源

注册顺序插入 D2 表：official 末尾依次为 `anthropic-api`、`openai-api`；chinese 在 `qbitai` 之后为 `aibase`。共 19 个来源。

| id | 名称 | 分类 | 请求 |
| --- | --- | --- | --- |
| `anthropic-api` | Anthropic API | official | `https://platform.claude.com/docs/en/release-notes/overview` |
| `openai-api` | OpenAI API | official | `https://developers.openai.com/api/docs/changelog` |
| `aibase` | AIbase 日报 | chinese | `https://www.aibase.com/zh/daily` |

地址于 2026-11-06 使用固定 User-Agent `TokenLens-News/0.1` 核实为 HTTP 200。Anthropic 的 `/docs/en/release-notes/api` 返回 307，因此直接请求表中的 overview 地址。不跟随重定向，不伪装浏览器 User-Agent，不带 Cookie，不执行 JavaScript，不用无头浏览器。

注册来源必须允许固定 User-Agent 直接读取服务端正文；拒绝该 User-Agent 或必须执行脚本的来源不进入注册表。

- 更新日志页按条目拆分：日期标题下的每个独立条目（段落或列表项）各算一条，不把整天合成一条。
  - `published_at` 取该日期的 `T00:00:00Z`。日期只精确到天，界面不显示时刻。
  - 标题取条目正文的第一句，最多 160 字符；描述取条目全文。两者都按 HTML 文本规范化。
  - `native_id` 为 `<YYYY-MM-DD>#<条目规范化正文的 FNV-1a 64 位哈希，16 位小写十六进制>`。哈希在模块内实现，保证跨 Rust 版本稳定，不使用 `DefaultHasher`。正文改动会产生新 id，这是可接受的。
  - 条目没有自己的链接时，`url` 用页面地址；页面提供日期锚点时加上锚点。
- AIbase 日报：列表页每一期为一条。标题和日期取列表展示的内容；描述取列表摘要，没有摘要时为空。不再请求每期的详情页。
  - 日期只取列表显示的日历日，存为当天 UTC 零点（例如 `2026年11月5号 16:39` 存为 `2026-11-05T00:00:00Z`）。列表时刻没有时区，不使用该时刻。这是只有日期的来源的统一约定：AIbase 与两个更新日志来源均存 UTC 零点，界面取 UTC 日期且不显示时刻。

### 跨来源去重的修订

同一来源内只按 `native_id` 去重，不再按 URL 合并，所以更新日志里共用同一页面地址的多个条目都会保留。跨来源时，规范化 URL 命中别的来源的主项，就写入该主项的 `also_in`；同一 URL 命中多个主项时，只写入排序最靠前的那一个。

### 条目类型

`NewsItem` 增加 `kind`，取值为 `release`、`api`、`deprecation`、`pricing`、`model`、`general` 之一。Rust 在规范化时按下面的顺序决定，先命中的生效：

1. **关键词**：只用于 official 和 tools 分类，只看规范化后的标题，不区分大小写；英文按词边界匹配，单词字符仅为 ASCII 字母、数字和 `_`，汉字不算单词字符。
   - `deprecation`：`deprecate`、`deprecated`、`deprecation`、`retire`、`retired`、`retirement`、`retiring`、`shut down`、`shutdown`、`sunset`、`end of life`、`弃用`、`下线`、`停用`、`退役`。
   - `pricing`：`price`、`prices`、`pricing`、`priced`、`价格`、`定价`、`降价`、`涨价`、`计费`。
   - 两类都命中时取 `deprecation`。
2. **来源结构**：`RawItem.kind` 来自页面明确给出的标签，比如更新日志条目上的类别标签。映射关系写在来源模块和本节里；不从自由文本推断。
   - Anthropic 没有条目级标签，保持 `None`。
   - OpenAI 的模型徽标（secondary soft 徽标，排除 `v1/...` endpoint）及显式 `Model: ...` 标签映射为 `model`；显式 `Deprecation`、`Deprecated`、`Retirement`、`Retired`、`Shutdown`、`Sunset`、`End of life` 标签映射为 `deprecation`，优先于模型徽标。`Feature`、`Update`、`Fix`、`Announcement` 不映射，保持 `None`。
3. **来源默认**：`Source::default_kind()`。GitHub Releases 为 `release`；`anthropic-api` 和 `openai-api` 为 `api`；其他来源为 `general`。

`model` 只来自来源结构，官方新闻里的新模型发布不靠猜测标成 `model`。

缓存仍是 v2，条目多一个 `kind`。读到缺少 `kind` 的条目时，用该来源的 `default_kind()` 补上；`kind` 不在六个取值之内时，按损坏缓存报 `cache`。FFI 的 `NewsItem` 增加 `kind: String`。

价格变动：本阶段只通过更新日志条目的 `pricing` 类型呈现，不抓取或比对价格页。

### Flutter

- 条目旁显示类型标签，`general` 不显示。标签用低饱和中性色，不用品牌色。
- 筛选新增“全部类型”下拉，支持多选，和分类、来源、搜索叠加。
- 来源筛选和分类筛选同时匹配主项来源和 `also_in`：条目的主项来源或 `also_in` 里任一已启用来源符合条件，就保留这条。分类计数按同一规则统计。条目仍然只显示主项来源。
- 排序有“最新”（默认）和“热度”两种。只有当前筛选结果里带热度的条目全部属于同一个 `popularity_kind` 时，“热度”才可选。这时按热度降序，没有热度的排在最后，同热度按时间。筛选变化导致条件不再满足时，自动回到“最新”。排序选择不持久化。
- 不跨平台换算热度，也不显示统一分数。

## D2.6 AI 热点改版

D2.6 在 D2.5 上增加 AIHOT 来源、条目首次收录时间、本机已读与收藏、定时刷新，并按新版界面重写页面。除下面写明的变化外，D2 / D2.5 的请求限制、错误类别、FFI 生命周期和目录隔离不变。

### AIHOT 来源

注册在 chinese 末尾，即 `aibase` 之后。共 20 个来源。

| id | 名称 | 分类 | 请求 |
| --- | --- | --- | --- |
| `aihot` | AIHOT 精选 | chinese | `https://aihot.news/feed.xml` |

地址于 2026-11-11 核实：HTTP 200，`application/rss+xml`，RSS 2.0，最新 50 条，`ttl` 30。AIHOT 公开说明欢迎用 RSS 订阅。响应上限 4 MiB。

- `native_id` 取 `guid`；`published_at` 取 `pubDate`；标题取 `title`，按 HTML 文本规范化。
- `description` 是 HTML，形如三段 `<p>`：摘要正文；`🔗 <a href="…">阅读原文</a>`；`via AIHOT · <a href="…/items/…">…</a>`。
  - 描述只取第一段正文，后两段丢弃。按 HTML 文本规范化，最多 4000 字符。
  - 找不到这个结构时，整段去标签作为描述，并且去掉“阅读原文”“via AIHOT”这两段文字。
- `url` 取“阅读原文”链接的 `href`，经现有安全 URL 校验（只留无凭据的 HTTP(S)）。没有这个链接或校验不过时，回退到 `link`（AIHOT 条目页）。用原始链接，是为了让它能和其他来源按 URL 合并。
- `origin` 取 `author` 括号里的文字，例如 `noreply@aihot.news (OpenRouter：Announcements)` 取 `OpenRouter：Announcements`；纯文本，最多 120 字符，没有括号就为空。界面只显示全角冒号前的部分。
- `kind`：`category` 整串为 `AI 模型` 时映射为 `model`（AIHOT 分类表 `ai-models` 的 feedLabel），其他取值都是 `general`。不做关键词匹配，因为 `aihot` 属于 chinese 分类。
- `popularity` 为空。AIHOT 的评分和热度不进 RSS，也不另行请求。
- 头像只用名称首字母，不用 AIHOT 的 Logo。

### 条目新字段

`NewsItem` 增加以下字段。缓存仍是 v2，读到缺字段的条目时按下表补上，下次成功提交时写回。

| 字段 | 含义 | 缺失时 |
| --- | --- | --- |
| `ai_summary: bool` | 描述由 AI 生成。只有 `aihot` 为 `true` | `false` |
| `origin: Option<String>` | 聚合来源给出的原始出处。只有 `aihot` 填写 | `None` |
| `first_seen_ms: i64` | 本机第一次在该来源的成功刷新里见到这条的时间，UTC epoch 毫秒 | 见下 |

`first_seen_ms` 的规则：
- 来源刷新成功、用新结果替换缓存时，旧缓存里已有的同 id 条目保留原 `first_seen_ms`。
- 新出现的条目，`first_seen_ms` 取本次刷新的 `now_ms`。
- 例外：该来源此前从没成功刷新过（缓存里没有它）时，新条目取 `published_at` 和 `now_ms` 中较早的一个；没有 `published_at` 就取 `now_ms`。这样首次安装时，不会把几百条旧内容全堆进“今天”。
- 已有缓存缺这个字段时，取 `published_at` 和该来源 `last_success_ms` 中较早的一个；两者都没有时取 `last_success_ms`；再没有就取读缓存时的 `now_ms`。
- 跨来源合并时，主项的 `first_seen_ms` 取主项与 `also_in` 各条目中最早的一个。

快照里 `items` 的排序改为：`first_seen_ms` 降序 → `published_at` 降序（无日期在后）→ 注册顺序。

### 本机已读与收藏

同一目录下新增 `news-state.json`，同样受 `news.lock` 保护，写法同缓存：写临时文件、同步、原子替换。格式：

```json
{"version":1,
 "read":{"<item_id>":<read_at_ms>},
 "starred":{"<item_id>":{"starred_at_ms":n,"item":{…NewsItem 全部字段…}}}}
```

- 文件不存在，等于空状态。版本未知或文件损坏时报 `cache`，不静默清空；这时缓存的条目照常显示，已读和收藏不可用。状态错误放在独立的 `NewsSnapshot.state_error: Option<NewsError>`（kind 为 `cache`），不占用 `error`；未知版本或损坏文件在本次运行内不覆盖，已读和收藏操作不写文件，错误保留到本次运行结束。
- 只存条目 id 和收藏副本，不存其他内容，不联网，不上传。
- 清理：每次成功写状态时，删掉 `read_at_ms` 早于 30 天前、而且当前任何来源缓存里都已没有的已读记录。收藏永不自动清理。
- 收藏保存条目副本。条目还在缓存里时，每次成功刷新后用最新内容更新副本；离开缓存后，副本照常保留和显示。
- 停用来源的收藏仍出现在“收藏”里。

FFI 新增：
- `set_read(ids: Vec<String>, read: bool) -> NewsSnapshot`：批量标已读或未读。未知 id 忽略；空列表不写文件。
- `set_starred(id: String, starred: bool) -> NewsSnapshot`：收藏或取消收藏。只能收藏当前快照里有、或已在收藏里的 id，否则忽略。
- `NewsItem` 增加 `read: bool`、`starred: bool`，由状态文件填写。
- `NewsSnapshot` 增加 `starred: Vec<NewsItem>`：全部收藏，按 `starred_at_ms` 降序；条目还在缓存里时，内容与 `items` 里的一致。
- `NewsSnapshot` 增加 `state_error: Option<NewsError>`：本机已读与收藏的状态文件错误，kind 为 `cache`，独立于 `error`。
- 状态写失败时报 `cache`，内存状态回到写之前，返回的快照反映真实落盘结果。

### 定时刷新

- 定时器由 Flutter 的 `NewsController` 持有，间隔固定 30 分钟，不做成设置项。写法照 `StatsController` 的 `Timer.periodic`；`dispose` 时取消，窗口关闭不留下定时器。
- 启动读完缓存后：如果所有已启用来源的 `last_success_ms` 都为空，或者都早于 30 分钟前，立即刷新一次全部来源；否则等下一个整周期。
- 每次到点时，以下情况跳过这一轮：
  - 当前正在刷新；
  - 距上一次刷新（手动或自动）开始不足 30 分钟；
  - 上一轮有任何来源报 `rate_limited`（只跳过一轮）。
- 自动刷新失败一般不立即重试，等下一个周期。例外是首次失败：一次刷新结束时，快照里没有任何条目，所有已启用来源都没有 `last_success_ms`，并且不是用户取消，就在 2 分钟后重试一次；那次再失败，10 分钟后再重试一次；之后回到每 30 分钟一次。任一来源刷新成功后，这个计数清零。重试走同一个 `refresh()`，同样受 busy 约束；到点时正在刷新就跳过这次重试。`shutdown` 时取消。
- 手动刷新照旧，不受定时器限制。
- 自动刷新走和手动刷新相同的 `refresh(None)`，同样会提交、可取消、受 busy 约束。

预算：一次全量刷新约用 7 次 GitHub 请求，每小时最多两次，即 14 次，在未登录每小时 60 次的限额内。

### D2.6 界面

页面改用统计页的 `LensPalette`、字体、字重和 `lib/stats/widgets/primitives.dart` 的控件；`_NewsColors` 删除。版式以原型 `prototype.html` 的定稿选项为准。

- **页头**：标题“AI 热点”。副标题写已启用来源数、最近一次刷新的时刻和“每 30 分钟自动刷新”。有来源出错时追加“N 个来源没更新”，点击打开管理来源。右侧是“管理来源”按钮和刷新图标按钮；刷新中这个按钮变成取消。删除“预览”徽标、说明卡片和页脚说明。刷新中，副标题写“正在刷新 · 已完成 x/y 个来源”，y 是本次刷新选中的来源数，x 是其中已结束（成功或失败）的数。
- **当前热点**：
  - 卡片，按来源分页。页签固定顺序为 `hn-ai`、`github-new`、`hf-models`、`hf-papers`、`hf-spaces`，只显示已启用、而且有带热度条目的来源；一个都没有时，整块不显示。
  - 每页列出该来源热度前 5 条，热度相同按 `first_seen_ms` 排。显示名次、标题和“数值 + 单位”：HN 为票，GitHub 为星，HF 为赞。
  - 不跨来源比较，不受分类、搜索、范围筛选影响。选中的页签只在本次会话内记住。
- **工具栏**：
  - 一行排下，滚动时吸顶。页面区域高度不足 560 逻辑像素，或字号放大超过 1.5 倍时，工具栏不吸顶，跟着页面滚动，以免占掉大半个窗口。
  - 依次是：分类小标签（全部 / 官方 / 工具更新 / 社区 / 中文）、范围分段（全部 / 未读 N / 收藏 N）、搜索框（按 `/` 聚焦；焦点在输入框里时不拦截）、筛选按钮。分类计数跟随当前范围、搜索和筛选，来源匹配规则同 D2.5。
  - 筛选按钮打开弹层，可多选已启用来源和类型；类型里有“常规（无标签）”，对应 `general`。有筛选时，按钮上显示圆点，工具栏下方列出可以逐个去掉的标签，外加“清除筛选”。
  - “最新 / 热度”分段只在 D2.5 的热度可选条件成立时出现，规则不变。
  - 删除列表 / 卡片布局切换。
- **边刷边显示**：刷新进行中，控制器每秒读一次 `snapshot()`，已完成来源的条目立即出现在列表里。同一时间最多一个读取在途；刷新结束、取消或关闭后停止读取；迟到的读取结果丢弃。最终以 `refresh()` 返回的快照为准。
- **列表**：
  - 按 `first_seen_ms` 的本地日历日分组，组头为“今天 · 11月12日 周四”“昨天 · …”“11月10日 周二”，不是今年的日期前加年份，如“2025年12月31日 周三”。组头带条数和未读数，未读不为 0 时有“本日标为已读”。按热度排序时不分组，显示为一组“按热度”。
  - 每条紧凑排列：
    - 左列是 `first_seen_ms` 的本地时刻 HH:mm；按热度排序时改为收录日期 MM/DD，因为一组里混着不同日子。悬停时显示发布时间；只有日期的来源不显示发布时刻。
    - 右侧三行：来源行（首字母头像、来源名、`aihot` 的出处、类型标签、热度、“另有 N 个来源”，悬停列出来源名）；标题；摘要最多两行。
    - `ai_summary` 的摘要前加“AI 摘要”标记。没有摘要不占行。
  - 未读：标题前有圆点，标题加粗；已读后去掉圆点，标题和摘要变浅。
  - 点击标题打开原文，同时标为已读；打开失败时提示，但仍算已读。
  - 每行右侧悬停时显示收藏和标已读 / 未读按钮；已收藏的星标常显。
  - 空状态：刷新中、还没有条目时，显示“正在获取动态 · 已完成 x/y 个来源”、占位行和“取消”，不显示“还没有动态”。首次失败、正在等待重试时，写“将在 HH:mm 自动重试”，并保留“立即刷新”。未读为空时显示“都读完了”；收藏为空时显示“还没有收藏”；被筛选清空时显示“没有符合条件的动态”和“清除筛选”。
- **提示条**：刷新出错时显示“刷新失败 · 正在查看离线缓存”，取消时显示“刷新已取消”。状态文件出错时显示固定说明“已读和收藏暂不可用”，不显示底层报错。
- **收藏视图**：数据取 `snapshot.starred`，不受来源启停影响，其他筛选照常叠加。
- **管理来源**：右侧抽屉，按分类列出全部来源。每行有首字母头像、名称、状态（几分钟前 / 刷新中 / 错误类别 + 上次成功时间 / 已停用）、启停开关；顶部写自动刷新说明，配“全部刷新”按钮；`aihot` 行标“AI 摘要”，底部一句说明它的标题和摘要由 AIHOT 生成。单来源刷新放在每行的菜单里。抽屉支持 Esc 关闭、焦点留在抽屉内、关闭后焦点回到打开它的按钮。
- **侧栏**：“AI 热点”导航项显示已启用来源的未读数，超过 99 显示“99+”，为 0 不显示。
- **已删除**：说明卡片、右侧固定来源栏、列表 / 卡片切换、排序说明文字。

## 已知限制

- DeepSeek 没有独立新闻索引页，依赖固定入口文章的侧边栏；该文章被删除时请求会返回 404，需要核实新的入口后更新注册地址。
- HN 的 `model` / `agent` 关键词较宽，`business model`、`user agent` 等标题可能误中；当前保留已验收规则。
- HF Spaces 列表没有描述，标题使用 id；不追加详情请求补齐。
- AIbase 日报列表没有摘要，描述为空。
- OpenAI API changelog 条目没有锚点，原文链接指向整页。
- OpenAI API changelog 依赖 CSS Modules 类名前缀（`_ChangelogPage_`、`_ChangelogMarkdown_`）定位；站点改版导致结构无法识别时返回 `parse`，保留旧缓存。
- Anthropic API 页面约 1.3 MB，包含全部历史；每次刷新在本地只保留最新 50 条。

- AIHOT 的标题和摘要由它的模型生成，可能与原文有出入；原文链接以原始出处为准。AIHOT 改 RSS 结构时，按「描述」一节的回退规则处理，结构完全无法识别时报 `parse`。
- `first_seen_ms` 只反映本机何时刷到。长时间没开程序后，第一次刷新会把这段时间里出现的条目都算到当天。
- 每个来源只缓存 50 条，较早的日期分组会越来越稀；收藏不受影响。
- 跨来源合并的条目，已读和收藏记在主项的 id 上。停用主项来源后，同一条改由另一个来源的条目当主项，显示为未读、未收藏；原来的收藏仍在“收藏”里。

## 验证

Rust 使用本地受控 HTTP server、仓库夹具和临时目录验证解析、缓存、限流、失败、取消、并发与关闭。Flutter 使用可替换 gateway 验证交互与晚到结果；真实 FFI 测试使用 Rust 库、loopback 来源和隔离目录验证多来源快照、参数传递、启停持久化与 v1 读取。Windows release 的启动、手动刷新和关闭另做桌面冒烟。macOS 构建与运行须在 macOS 取得证据，Windows 测试不能替代。
