# AI 动态

## 阶段与来源

D1 为独立桌面预览，只接入 [OpenAI News RSS](https://openai.com/news/rss.xml)。预览不读取客户端日志或统计账本。D2 再接入下列来源，不在 D1 显示不可用的来源开关。

| 类型 | D2 来源 |
| --- | --- |
| 官方 RSS | Google DeepMind、Google AI |
| 官方网页 | DeepSeek |
| 工具正式版更新 | GitHub Releases：Claude Code、Codex、Gemini CLI、OpenCode、Pi、Ollama |
| 社区发现 | GitHub 新项目、Hugging Face 模型／Spaces／论文、Hacker News AI 相关筛选 |
| 中文资讯 | 量子位官方 RSS |

Anthropic 官网动态、Qwen 与机器之心待后续接入；X 不进入首版。Claude Code 的 GitHub 版本更新不等同于 Anthropic 官网动态。

## 请求和呈现

- Rust 是来源访问与缓存的唯一所有者；Flutter 只通过生成的 FFI 接口调用它，不另行发送来源请求。
- 启动只读取缓存。只有点击刷新才请求固定 RSS URL，没有定时刷新、后台补抓、自动重试、追踪像素或远程图片。打开原文需用户点击，交给系统浏览器。
- 请求总超时 20 秒，响应上限 4 MiB，不跟随重定向。HTTP 429、网络失败、超时与解析失败单独报告；200 HTML 不是成功的 RSS。
- 来源标题、日期、短描述转换为纯文本；只保留 HTTP(S) 原文链接，不渲染 HTML。没有摘要时留空，不调用模型生成摘要，也不读取来源的 AI 摘要字段。
- 最多保留 100 条新闻，按来源身份去重。列表和卡片展示同一数据，刷新不清空已有内容。

## FFI 与缓存契约

`NewsClient` 是不透明 Rust 对象，构造时必须提供绝对数据目录；构造不联网。`snapshot()` 只读状态，`refresh()` 执行一次请求，`cancel_refresh()` 取消当前请求，`shutdown()` 幂等关闭。文件和锁操作在 Rust 工作线程执行，Flutter 等待 Future，不阻塞 UI 线程。

`NewsSnapshot` 包含 `items`、`last_success_ms`（UTC epoch milliseconds，可空）、`refreshing` 和可空 `error`。条目包含稳定 `id`、纯文本 `title`、HTTP(S) `url`、可空来源日期 `published_at` 和可空 `description`。错误包含稳定类别 `kind` 与安全信息 `message`；Flutter 将类别转换为中文提示，不向界面输出底层完整响应。

每个数据目录以 `news.lock` 独占，拒绝第二个写入者。`news-cache.json` 的版本为 1，仅保存新闻与最后成功时间；未知版本或损坏缓存显式报错，不静默当作空结果。成功刷新写入同目录临时文件后原子替换；失败或取消保留原缓存。缓存不包含凭据、客户端日志、用量或账本数据。

状态为 idle → refreshing → success / failed / cancelled。重复刷新拒绝并发；取消与提交按 Rust 状态锁裁决，已取消或关闭的请求不能再提交。关闭先禁止新请求、取消活动请求并释放目录锁；进程退出不留下工作进程。取消前已完成的原子提交仍是有效成功结果。

预览默认使用系统应用支持目录下的独立 `news-preview` 目录。开发与测试必须设置绝对路径 `TOKEN_LENS_PREVIEW_DATA_DIR`；旧版 `TOKEN_LENS_DATA_DIR`、`DB_PATH` 不参与预览目录选择。D1 不对旧账本执行迁移或兼容写入。

## D2 多来源契约

本节约束 D2。D1 的请求、纯文本、缓存原子替换、单写者、取消与关闭语义保持不变；本节只写变化和新增部分。

### 来源注册

每个来源是一次刷新里的一个请求单元，带稳定 `id`、显示名、分类和主页。分类有四个：`official`（官方）、`tools`（工具更新）、`community`（社区发现）、`chinese`（中文资讯）。

| id | 名称 | 分类 | 请求 |
| --- | --- | --- | --- |
| `openai` | OpenAI | official | RSS `https://openai.com/news/rss.xml` |
| `deepmind` | Google DeepMind | official | RSS（实现时核实地址） |
| `google-ai` | Google AI | official | RSS（实现时核实地址） |
| `deepseek` | DeepSeek | official | 官方网页的新闻列表（实现时核实页面） |
| `gh-release:<owner>/<repo>` | 仓库显示名 | tools | GitHub REST `GET /repos/<owner>/<repo>/releases?per_page=20`，只保留非 draft、非 prerelease |
| `github-new` | GitHub 新项目 | community | GitHub Search：最近 7 天创建的 AI 相关仓库，按 star 降序 |
| `hf-models`、`hf-spaces`、`hf-papers` | Hugging Face 模型／Spaces／论文 | community | Hugging Face 公开 API：热门模型、热门 Spaces、Daily Papers |
| `hn-ai` | Hacker News | community | HN Algolia `front_page`，用本地关键词规则筛出 AI 相关条目 |
| `qbitai` | 量子位 | chinese | RSS（实现时核实地址） |

工具更新的六个仓库是 Claude Code、Codex、Gemini CLI、OpenCode、Pi、Ollama。仓库路径在实现时核实，写进注册表常量。每个来源只请求一个 URL；请求限制沿用 D1：20 秒超时、4 MiB、不跟随重定向、固定 User-Agent。未登录的 GitHub API 每小时限 60 次，一次全量刷新约 7 次请求，碰到限流按 429 报告。

### Rust 内部接口

`app/rust/src/sources/mod.rs` 定义 `Source` trait，每个来源模块各实现一个。来源模块是纯函数：只拼 URL、解析响应体，不做 I/O、不读时钟（需要时间窗口的来源从参数拿 `now_ms`）。框架负责：请求和限制、Content-Type 检查、纯文本化（去标签、解码实体、合并空白、截断）、URL 校验、条目 id 拼接、去重、缓存、状态。

- `parse` 返回 `Ok(空列表)` 表示来源确实没有内容；结构变了、必需字段全缺，或所有条目都无效，返回 `ParseError`，而且不覆盖该来源的旧缓存。
- 条目的 `native_id` 在来源内唯一，取 guid、release id 或链接等稳定值。条目 id 是 `<source_id>:<native_id>`。
- 热度（`popularity`）只保留平台原生数值：HN points、GitHub stars、HF likes 或 upvotes，不做跨平台换算。

### FFI

- `NewsSnapshot`：`sources: Vec<SourceState>`、`items: Vec<NewsItem>`、`refreshing: bool`、`error: Option<NewsError>`。顶层 `error` 只放与来源无关的错误（busy、closed、cache）。
- `SourceState`：`id`、`name`、`category`（上面四个字符串之一）、`home_url`、`enabled`、`refreshing`、`last_success_ms`（可空）、`error`（可空，本次会话最近一次失败）。
- `NewsItem`：在 D1 字段基础上增加 `source_id`、`popularity_kind`（`points`、`stars`、`likes`、`upvotes` 之一，可空）、`popularity`（可空整数）、`also_in: Vec<String>`（同一 URL 在其他来源也出现时，记那些来源的 id）。
- `refresh(source_ids: Option<Vec<String>>)`：`None` 表示刷新全部已启用来源，否则只刷新给定来源，忽略未知或已停用的 id。最多 4 个来源并发；某个来源失败不影响其他来源。每个来源完成后单独原子提交缓存；取消会停掉还没完成的来源，已提交的保留。
- `set_source_enabled(id, enabled)` 持久化启停状态，返回新快照；停用的来源不参与刷新，其条目不出现在 `items` 里，但缓存保留。
- 错误类别沿用 D1，新增 `rate_limited`（HTTP 429 和 GitHub 的 403 限流）与 `http`（其他非 200 状态）。

### 去重与排序

- 来源内按 `native_id` 去重。
- 跨来源按规范化 URL 去重：小写 scheme 和 host，去掉 fragment、`utm_*` 参数和末尾 `/`。保留优先级最高的来源，顺序是 official、chinese、tools、community，同分类按注册表顺序；被合并的来源 id 写进 `also_in`。去重只发生在组装快照时，缓存里各来源的数据保持原样。
- `items` 按 `published_at` 降序，没有日期的排在最后，彼此之间按注册表顺序。每个来源最多缓存 50 条。

### 缓存 v2

`news-cache.json` 升到版本 2：`{"version": 2, "sources": {<id>: {"items": [...], "last_success_ms": n}}, "disabled": [<id>...]}`。读到版本 1 时，把其中的条目迁到 `openai` 来源下，下次成功提交时写成 v2；未知版本仍按 D1 显式报错。来源的错误不写进缓存。

### Flutter

Flutter 通过 `NewsGateway` 拿快照，搜索和筛选（分类、来源）都在本地对 `items` 做，不再调用 Rust。界面按来源显示刷新状态、上次成功时间和错误；某个来源失败时其他来源照常显示。全部刷新和单来源刷新都只在用户点击时发生。

## 验证

Rust 通过本地受控 HTTP server 和隔离临时目录验证解析、缓存、限流、失败、取消、并发及关闭。Flutter 通过可替换 gateway 验证启动不刷新、按钮触发、错误保留内容和销毁后的晚到结果。FFI 集成检查使用真实 Rust 库和隔离目录；桌面产物另行验证打开、关闭与重复启动。macOS 构建和运行必须在 macOS 取得证据，Windows 测试不能替代。
