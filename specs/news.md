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

## 验证

Rust 通过本地受控 HTTP server 和隔离临时目录验证解析、缓存、限流、失败、取消、并发及关闭。Flutter 通过可替换 gateway 验证启动不刷新、按钮触发、错误保留内容和销毁后的晚到结果。FFI 集成检查使用真实 Rust 库和隔离目录；桌面产物另行验证打开、关闭与重复启动。macOS 构建和运行必须在 macOS 取得证据，Windows 测试不能替代。
