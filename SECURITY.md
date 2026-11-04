# 安全政策

## 支持的版本

| 版本 | 支持状态 |
| --- | --- |
| 1.0.x（main 最新版） | 接收安全修复 |
| 更早版本 | 不回补安全修复，请升级到最新版 |

## 报告漏洞

请勿公开提交安全 issue。请通过 GitHub 私密漏洞报告渠道联系维护者：

https://github.com/rumoii/token-lens/security/advisories/new

报告请包含：

- 受影响的版本（发布版本或 commit）；
- 复现步骤；
- 影响面评估，附最小 PoC 更好。

请不要附真实日志、令牌或含个人用户名的路径。

响应预期：确认收悉后尽快评估；修复合入 main 后与报告者协调公开披露时间。

## 重点范围

1. HTTP 准入闸门 `src/core/http/gate.js`：仅接受回环 Host（其余一律返回 421）；`/api/*` 需要 bearer 令牌（缺失或错误返回 401）；写请求的 Origin 须同源或缺省（否则 403）；永不下发 CORS 头。
2. API 令牌 `src/core/http/token.js`：令牌存于 `<data-dir>/api-token`，POSIX 上文件权限 0600（Windows 上依赖用户目录 ACL）；`index.html` 以 meta 注入令牌，比较用定长比较。
3. 数据目录裁决 `src/core/paths.js`：`--data-dir` > `TOKEN_LENS_DATA_DIR` > `DB_PATH` > 默认 `~/.token-lens`；`DB_PATH` 与 `--data-dir`/`TOKEN_LENS_DATA_DIR` 指向不同目录时直接报错，防止误写真实 HOME。
4. 日志解析只读不执行代码 `src/core/adapters/`：只做 JSON / JSONL / SQLite 的只读解析与 zstd 多帧解码（`src/core/adapters/_zstd.js`），不 eval、不加载客户端配置、不写客户端目录。
5. 网络面：服务仅绑定回环地址 127.0.0.1（`src/core/http/port.js` 的 `server.listen(port, '127.0.0.1')`），从不绑定 0.0.0.0，也不接受非回环 Host 请求；联网只发生在用户明确点击设置页「更新汇率」时。
6. 桌面壳 `desktop/src/`：
   - 窗口只导航到 `http://127.0.0.1:3456` 和内联的加载、失败页；其他 http(s) 链接和新窗口请求交给系统浏览器，其余协议与本地文件一律拒绝（`main.rs`，`runtime/windows.rs` 与 `runtime/macos.rs` 的 `open_external`）。
   - Windows：内核 `node.exe` 挂在带 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job 里，关窗或壳崩溃时一并结束；命名互斥量保证单实例（`runtime/windows.rs`）。
   - macOS：壳一直持有内核 stdin 的写端，内核带 `--exit-on-stdin-end`，壳退出或崩溃时管道关闭，内核随之退出；单实例靠 `~/Library/Application Support/token-lens-app/instance.lock` 的文件锁；错误对话框的消息经 argv 传给 `osascript`，不拼进脚本（`runtime/macos.rs`）。
   - 自解压（`payload.rs`，仅 Windows）：先校验压缩载荷的 SHA-256，拒绝越界路径、重复路径、截断与超限数据；解压到临时目录，用 `create_new` 写文件，全部校验通过后写完成标记并原子改名，不覆盖已有文件。

## 不算漏洞的情况

- 以已获得本机用户账户或文件系统权限为前提的攻击；
- 本机恶意软件造成的任何后果；
- 本地端口占用或本地拒绝服务（命令行版端口被占时顺延、桌面版被占时报错，都是既定设计）；
- 桌面版未签名或未公证导致的 SmartScreen、Gatekeeper 提示，或替换 `%LOCALAPPDATA%\token-lens-app\`、`Token Lens.app` 里的程序文件（需要本机用户权限，归入第一条）；
- 价格数值错误（属于功能缺陷，请走 issue 反馈）；
- 未结合本项目实际调用面的纯依赖审计告警；
- 社会工程学攻击。

## 处理流程

收悉 → 复现与影响评估 → 修复合入 main → 通知报告者 → 可选致谢（需报告者同意）。

## English Summary

Token Lens runs entirely on the local machine. The local server binds only to the loopback address 127.0.0.1 (never 0.0.0.0) and rejects requests with a non-loopback Host; every `/api/*` endpoint requires a bearer token. The desktop app (Windows and macOS) runs the same server and its window only loads `http://127.0.0.1:3456`, handing other web links to the system browser. No usage data or telemetry is ever uploaded and no account is involved. Please report security vulnerabilities privately through GitHub's private vulnerability reporting channel.
