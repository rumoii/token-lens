# 安全政策

## 支持的版本

| 版本 | 支持状态 |
| --- | --- |
| 最新发布的桌面版（0.x 期间是最新的 0.y.z） | 接收安全修复 |
| 更早的桌面版 | 不回补安全修复，请升级到最新版 |

## 报告漏洞

请勿公开提交安全 issue。请通过 GitHub 私密漏洞报告渠道联系维护者：

https://github.com/rumoii/token-lens/security/advisories/new

报告请包含：

- 受影响的版本（发布版本或 commit）和系统；
- 复现步骤；
- 影响面评估，附最小 PoC 更好。

请不要附真实日志、令牌或含个人用户名的路径。

响应预期：确认收悉后尽快评估；修复合入 main 后与报告者协调公开披露时间。

## 重点范围（桌面应用 `app/`）

1. **进程结构**：界面是 Flutter，统计、计价、新闻刷新都在随程序分发的 Rust 库里，通过 flutter_rust_bridge 在同一进程内调用。没有本地网页服务，不监听端口，不用 WebView。
2. **日志解析只读、不执行代码**（`app/rust/src/stats/adapters/`）：只做 JSON / JSONL / SQLite 的解析和 zstd 多帧解码；SQLite 以只读方式打开；不 eval，不加载客户端配置，不写、不删客户端目录里的任何文件。
3. **数据目录**：账本、偏好、新闻缓存和运行日志都在当前用户的应用支持目录（Windows `%APPDATA%\Token Lens\Token Lens\data`，macOS `~/Library/Application Support/io.github.rumoii.token-lens/data`）。`TOKEN_LENS_PREVIEW_DATA_DIR`、`TOKEN_LENS_PREVIEW_HOME` 只给开发和冒烟测试隔离用。桌面版从不打开旧版的 `~/.token-lens`。
4. **联网面**（详见 [隐私说明](PRIVACY.md#什么时候联网)）：
   - AI 热点：每个来源只请求固定地址，不加载远程图片；条目链接在 Rust 端只保留 http/https 地址（`safe_url`），其他协议的链接被丢弃。
   - 汇率：只在用户点「更新汇率」时请求一次。
   - 检查更新：只向 `api.github.com` 请求本项目最新正式版本，不跟随重定向，响应超过 512 KiB 中止；下载页地址由校验过的版本号拼出，不使用响应里的链接（[docs/development/update.md](docs/development/update.md)）。
   - 所有外部链接交给系统默认浏览器打开。
5. **诊断导出**（`app/rust/src/diagnostics.rs`）：只在用户点击时生成；不含账本和对话内容；先把用户主目录替换成 `~`，再过滤敏感字段，最后截断。

## 不算漏洞的情况

- 以已获得本机用户账户或文件系统权限为前提的攻击，包括改写数据目录里的文件、替换程序文件夹或 `Token Lens.app` 里的文件；
- 本机恶意软件造成的任何后果；
- 本地拒绝服务，例如塞入超大或畸形的客户端日志让同步变慢（请走普通 issue）；
- 桌面版未签名或未公证导致的 SmartScreen、Gatekeeper 提示；
- 新闻来源本身发布的内容不准确或不当（请走普通 issue，可在「管理来源」里停用该来源）；
- 价格数值错误（属于功能缺陷，请走 issue 反馈）；
- 未结合本项目实际调用面的纯依赖审计告警；
- 社会工程学攻击。

## 处理流程

收悉 → 复现与影响评估 → 修复合入 main → 通知报告者 → 可选致谢（需报告者同意）。

## English Summary

Token Lens runs entirely on the local machine. The desktop app is a Flutter UI calling a Rust library in-process: it runs no local server, listens on no port and uses no WebView. It reads AI tools' local logs read-only (SQLite databases are opened read-only) and never modifies them. It uses the network for three things only: refreshing AI news from fixed source URLs (item links are limited to http/https), fetching an exchange rate when the user clicks "Update rate", and checking GitHub for a newer release at most once a day (no redirects, response size capped, the download link is built from the validated version). No usage data or telemetry is ever uploaded and no account is involved. Please report vulnerabilities privately through GitHub's private vulnerability reporting channel.
