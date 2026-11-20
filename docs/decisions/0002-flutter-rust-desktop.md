# 0002 桌面应用用 Flutter 界面加 Rust 核心重写

日期：2026-11-05　状态：有效

## 背景

最早的版本是 Node CLI 加浏览器看板，后来用 wry 包了一层桌面壳（W/M 阶段）：启动时在本机起一个只监听回环的 HTTP 服务，再用 WebView 打开它，打包要带上 Node。这一层带来了端口、API 令牌和 Host/Origin 校验等一整套边界。

## 决定

- 整体重写：界面用 Flutter，统计、计价、新闻刷新放进 Rust 库，通过 flutter_rust_bridge 在进程内调用，库随桌面包分发。这是产品方向的选择；资源占用是否下降，当时约定迁移完成后用相同数据另行测量（结果见 [stats.md](../development/stats.md)「D3.5」）。
- 没有本地 HTTP 服务，不用 WebView，不附带 Node。
- 只做 Windows x64 和 macOS arm64 桌面应用；关闭窗口即退出，不常驻后台。
- 迁移以旧版为行为基线：适配器、记录身份、内容哈希、计价都和旧版逐字节对拍，旧版生成的金标准留在 `app/rust/tests/golden/`。

技术细节和阶段记录见 [desktop.md](../development/desktop.md)。

## 放弃的做法

- 继续沿用 wry 壳加 Node 内核。W 阶段选型时比较过的其他壳（Tauri 2 内核原生化、内置 Node 的 Tauri 或 Electron 等）记录在 [legacy-desktop.md](../archive/legacy-desktop.md)「选型」。

## 后果

- 开发要同时装 Flutter 和 Rust 两套工具链，改 Rust 公共接口后要重新生成桥接代码。
- 只读 JSON 命令行 `token-lens-cli` 复用同一个 Rust 库，后来补上了旧版 CLI 的用途。
