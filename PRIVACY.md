# 隐私说明

最后更新：2026-11-05

本工具 100% 在本地运行：不登录、不上传、零遥测。命令行版和桌面版（Windows、macOS）处理的数据相同。本文说明它处理哪些数据、数据放在哪里、如何删除。

## Flutter 新闻预览

`app/` 是独立的桌面预览，不读取客户端日志或旧版 `~/.token-lens` 账本。启动只读取本地新闻缓存；用户点击「刷新」后向 `https://openai.com/news/rss.xml` 发送普通 HTTPS 请求。来源服务器可以看到该请求的 IP 和 `TokenLens-News/0.1` User-Agent；请求不携带账户、凭据或用量数据。没有后台刷新、自动重试、远程图片、模型摘要调用或遥测。点击原文才交给系统浏览器访问该文章。

预览缓存与 `news.lock` 位于系统应用支持目录下的独立 `news-preview` 目录；开发测试使用 `TOKEN_LENS_PREVIEW_DATA_DIR` 指定隔离目录。缓存仅保存来源标题、短描述、日期、链接和最后成功时间；关闭应用后可以删除整个预览目录。预览通过进程内 Rust 库读取数据，不使用 WebView 或本地 HTTP 服务。下面各节描述现有统计版本。

## 处理的数据

- 只读解析各客户端已经落盘的日志与数据库中的用量元数据：四类 token 计数（输入、输出、缓存读、缓存写）、模型名、时间、会话标识、项目路径（字段契约见 [specs/adapters.md](specs/adapters.md)）。
- 不读取也不保存提示词、回复、代码、附件、凭据（见 [specs/features.md](specs/features.md)）。
- 解析结果写入本地账本数据库（ledger.db）的 `usage_records` 等表：以 SHA-256 内容哈希幂等去重，金额以整数微美元存储。

## 数据传输

- 无上传、无遥测、无账号、无第三方分析。
- 本地服务只监听 127.0.0.1；`/api/*` 需要 bearer 令牌；拒绝非回环 Host 请求；不下发 CORS 头。桌面版的窗口同样通过 `http://127.0.0.1:3456` 访问这个本地服务。
- 汇率只支持 USD/CNY；只有用户明确点击设置页的「更新汇率」按钮才请求外部汇率接口。页面加载、后台同步与定时器都不会触发该请求。
- 桌面版窗口里点开的外部链接交给系统默认浏览器打开，窗口本身只显示本地页面。
- 桌面版窗口使用系统自带的 Microsoft Edge WebView2 运行时。WebView2 自身的更新与诊断数据遵循 Windows 和 Microsoft Edge 的设置，不由本工具控制。macOS 桌面版使用系统自带的 WKWebView（WebKit），同样遵循 macOS 的设置。

## 数据保留与删除

- 全部数据都在数据目录内（默认 `~/.token-lens`）：账本数据库 `ledger.db` 与 API 令牌文件 `api-token`；采集与同步期间另有独立互斥数据库 `sync-lock.db`（基于 SQLite 写事务锁，释放时不删除）。
- 桌面版还会在数据目录里写入：
  - `logs/kernel.log`：本地服务的控制台输出，包括数据目录路径、端口、本机局域网 IP（只用于提示「不提供局域网访问」）、每次同步的新增条数，以及读取失败时客户端日志文件的路径和错误信息，不含提示词或回复；每个文件最多 5MiB，连同 `.1`、`.2` 最多保留三份。
  - `webview/`（仅 Windows）：窗口的浏览器数据，包括看板设置（主题、周期、货币等）和页面缓存。macOS 上这部分由系统 WebKit 存在 `~/Library/WebKit/io.github.rumoii.token-lens` 和 `~/Library/Caches/io.github.rumoii.token-lens`。
- 桌面版的程序文件解压在 `%LOCALAPPDATA%\token-lens-app\<版本>\`，只有程序，没有用量数据。新版本解压到新目录，旧目录不会自动删除。macOS 桌面版的程序就是拖进「应用程序」的 `Token Lens.app`，另外在 `~/Library/Application Support/token-lens-app/` 留一个单实例锁文件。
- 记录只更新不删除：每次修订都保留版本轨迹（revision / active / superseded_by），用于追溯同一记录的演变。
- 要彻底删除数据，删掉整个数据目录即可（演示环境的数据目录，例如 `/tmp/token-lens-demo`，同理）。不再使用 Windows 桌面版时，再删掉 `%LOCALAPPDATA%\token-lens-app\` 和 exe 本身；不再使用 macOS 桌面版时，删掉 `Token Lens.app`、`~/Library/Application Support/token-lens-app/` 和上面两个 WebKit 目录。

## 用户可控项

- 数据目录裁决顺序：`--data-dir` > `TOKEN_LENS_DATA_DIR` > `DB_PATH` > 默认 `~/.token-lens`；`DB_PATH` 与 `--data-dir`/`TOKEN_LENS_DATA_DIR` 指向不同目录时报错而不是猜测（`src/core/paths.js`）。桌面版同样按这个顺序取环境变量。
- 命令行版的采集是手动的：`npm run collect`。
- 定时同步每 5 分钟一次，但只在 serve 运行期间存在：命令行版不启动 serve、桌面版不开窗口，就没有任何后台行为。桌面版关窗即退出，没有托盘、后台进程或开机自启。
- `api-token` 被删除后，下一次启动会重新生成。

## 联系方式

隐私相关问题与安全报告走同一渠道：[安全政策 · 报告漏洞](SECURITY.md#报告漏洞)。
