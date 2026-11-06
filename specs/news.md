# AI 动态

## 阶段与联网边界

D2 桌面预览接入下列 16 个来源。Rust 是来源访问和缓存的唯一所有者；Flutter 通过生成的 FFI 调用，不发送来源请求。预览不读取客户端日志或统计账本，统计功能继续使用原有版本。

启动只读取缓存。全量或单来源请求只在用户点击刷新后发生，没有定时刷新、后台补抓、自动重试、追踪像素或远程图片。打开原文需用户点击，交给系统浏览器。搜索、分类和来源筛选只处理本地快照。

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

每个来源只请求一个 URL。总超时 20 秒，响应默认上限 4 MiB；GitHub Releases 例外为 16 MiB，因为响应包含大量 release assets 元数据，Codex 的 20 条响应可能超过 4 MiB。`Source::max_body_bytes()` 声明来源上限，框架同时检查 Content-Length 和流式累计字节数；gzip 响应由 reqwest 协商并自动解压，解压后不保留压缩体的 Content-Length，流式上限按解压后的字节计算；GitHub 新项目与其他来源仍为 4 MiB。不跟随重定向，不自动重试。固定 User-Agent 为 `TokenLens-News/0.1`，不手动设置 Accept-Encoding，由 reqwest 协商 gzip。有 Content-Type 时，框架在解析前检查 `accepts()` 中的前缀；保留对缺少该 header 的兼容。

HTTP 429 和 GitHub 来源带 `x-ratelimit-remaining: 0` 的 HTTP 403 报 `rate_limited`；其他非 200 报 `http`。网络失败、超时、正文解析失败分别报 `network`、`timeout`、`parse`；超过来源上限报 `too_large`，Content-Type 不受来源支持报 `content_type`。200 HTML 不能当作成功 RSS。未登录 GitHub API 每小时限 60 次，一次全量刷新使用 7 次 GitHub 请求。

标题和短描述转换为纯文本：RSS 和 DeepSeek 的 HTML 文本去标签、解码实体；GitHub Releases、GitHub 新项目、HF 三个来源和 HN 的纯文本不解析标签、不解码实体，保留 `Vec<String>` 和 `<script>` 等字面量。两类文本均合并空白、移除控制字符并截断；标题最多 512 字符，描述最多 4000 字符。GitHub Releases 的描述先移除 Markdown 标题行（1–6 个 `#` 后接空格或行尾）、列表符号、成对的粗体标记和反引号，链接只留文字，删除裸 URL，合并空白后最多保留 300 字符；`#123 fix leak` 等非标题行保留，清理后为空则为 `None`。不渲染 HTML，只保留无凭据的 HTTP(S) 原文链接。没有描述就留空，不调用模型生成，也不读取来源的 AI 摘要字段。

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

来源内按 `native_id` 去重。快照跨来源按规范化 URL 去重：小写 scheme 和 host，去 fragment、`utm_*` 参数和末尾 `/`。优先级为 official、chinese、tools、community，同分类按注册顺序。保留主项，将其他来源 id 写入 `also_in`。合并只发生在快照中，不改各来源缓存。

`items` 按 `published_at` 降序；无日期在最后，同日期或无日期按注册顺序。每来源最多缓存 50 条。成功刷新用本次结果整体替换该来源的缓存（`Ok` 空列表即该来源确实无内容）；失败和取消保留旧缓存；刷新进行中界面保留已有内容。

### 缓存 v2 与隔离目录

每目录以 `news.lock` 独占，拒绝第二个写入者。`news-cache.json` 格式为 `{"version":2,"sources":{<id>:{"items":[...],"last_success_ms":n}},"disabled":[<id>...]}`。来源错误不写缓存，缓存不包含凭据、客户端日志、用量或账本数据。

读取 v1 时将条目迁到 `openai`，id 增加 `openai:` 前缀；仅在内存迁移，下次成功提交时写成 v2。未知版本或损坏缓存显式报 cache，不静默当作空结果。成功提交先写同目录临时文件并同步，再原子替换；失败和取消保留旧缓存。v2 不承诺供旧版 D1 读取。

默认使用系统应用支持目录中的独立 `news-preview`。开发和测试必须设置绝对 `TOKEN_LENS_PREVIEW_DATA_DIR`，不得指向真实 home、统计账本或安装版数据。`TOKEN_LENS_DATA_DIR` 与 `DB_PATH` 不参与预览目录选择。预览不迁移或写入真实账本。

### Flutter

Flutter 通过 `NewsGateway` 读取快照，搜索、分类和来源多选在本地叠加。列表与卡片展示同一数据，按来源呈现刷新状态、上次成功时间和错误；部分失败时其他来源内容继续显示。全量刷新和单来源刷新只在用户点击时触发。

## D2.5 开发者变更

D2.5 在 D2 契约上增加官方 API 变更来源、中文日报来源、条目类型和来源内热度排序。除下面写明的变化外，D2 的联网边界、请求限制、缓存、FFI 生命周期和错误类别不变。

### 新来源

注册顺序插入 D2 表：official 末尾依次为 `anthropic-api`、`openai-api`；chinese 在 `qbitai` 之后为 `aibase`。共 19 个来源。

| id | 名称 | 分类 | 请求 |
| --- | --- | --- | --- |
| `anthropic-api` | Anthropic API | official | Claude 平台 API release notes 页 |
| `openai-api` | OpenAI API | official | OpenAI API changelog 页 |
| `aibase` | AIbase 日报 | chinese | AIbase 中文日报列表页 |

- 实现时用固定 User-Agent `TokenLens-News/0.1` 核实最终地址，写回本表。不跟随重定向，所以表中必须是最终 200 的地址。不伪装浏览器 User-Agent，不带 Cookie，不执行 JavaScript，不用无头浏览器。
- 站点拒绝固定 User-Agent，或正文要执行脚本才能得到时，该来源不进入注册表。把状态码和响应特征写进「已知限制」，D2.5 的其他部分照常交付。
- 更新日志页按条目拆分：日期标题下的每个独立条目（段落或列表项）各算一条，不把整天合成一条。
  - `published_at` 取该日期的 `T00:00:00Z`。日期只精确到天，界面不显示时刻。
  - 标题取条目正文的第一句，最多 160 字符；描述取条目全文。两者都按 HTML 文本规范化。
  - `native_id` 为 `<YYYY-MM-DD>#<条目规范化正文的 FNV-1a 64 位哈希，16 位小写十六进制>`。哈希在模块内实现，保证跨 Rust 版本稳定，不使用 `DefaultHasher`。正文改动会产生新 id，这是可接受的。
  - 条目没有自己的链接时，`url` 用页面地址；页面提供日期锚点时加上锚点。
- AIbase 日报：列表页每一期为一条。标题和日期取列表展示的内容；描述取列表摘要，没有摘要时为空。不再请求每期的详情页。

### 跨来源去重的修订

同一来源内只按 `native_id` 去重，不再按 URL 合并，所以更新日志里共用同一页面地址的多个条目都会保留。跨来源时，规范化 URL 命中别的来源的主项，就写入该主项的 `also_in`；同一 URL 命中多个主项时，只写入排序最靠前的那一个。

### 条目类型

`NewsItem` 增加 `kind`，取值为 `release`、`api`、`deprecation`、`pricing`、`model`、`general` 之一。Rust 在规范化时按下面的顺序决定，先命中的生效：

1. **关键词**：只用于 official 和 tools 分类，只看规范化后的标题，不区分大小写；英文按词边界匹配。
   - `deprecation`：`deprecate`、`deprecated`、`deprecation`、`retire`、`retired`、`retirement`、`retiring`、`shut down`、`shutdown`、`sunset`、`end of life`、`弃用`、`下线`、`停用`、`退役`。
   - `pricing`：`price`、`prices`、`pricing`、`priced`、`价格`、`定价`、`降价`、`涨价`、`计费`。
   - 两类都命中时取 `deprecation`。
2. **来源结构**：`RawItem.kind` 来自页面明确给出的标签，比如更新日志条目上的类别标签。映射关系写在来源模块和本节里；不从自由文本推断。
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

## 已知限制

- DeepSeek 没有独立新闻索引页，依赖固定入口文章的侧边栏；该文章被删除时请求会返回 404，需要核实新的入口后更新注册地址。
- HN 的 `model` / `agent` 关键词较宽，`business model`、`user agent` 等标题可能误中；当前保留已验收规则。
- HF Spaces 列表没有描述，标题使用 id；不追加详情请求补齐。

## 验证

Rust 使用本地受控 HTTP server、仓库夹具和临时目录验证解析、缓存、限流、失败、取消、并发与关闭。Flutter 使用可替换 gateway 验证交互与晚到结果；真实 FFI 测试使用 Rust 库、loopback 来源和隔离目录验证多来源快照、参数传递、启停持久化与 v1 读取。Windows release 的启动、手动刷新和关闭另做桌面冒烟。macOS 构建与运行须在 macOS 取得证据，Windows 测试不能替代。
