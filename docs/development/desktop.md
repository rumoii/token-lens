# 桌面应用（Windows、macOS）

## 重写决定（2026-11-05）

状态：D1、D2、D2.5、D2.6（新闻）、D3.1–D3.5（统计）和 D4（数据副本验收与切换）已完成。旧版 Node/React 工具在 v0.1.0 之前从仓库删除，删除前的最后一个提交打了标签 `legacy-node`。发布流程打 zip 包（见 [release.md](release.md)）；安装程序和 macOS 真机验收尚未排期。

采用 Flutter 界面 + Rust 核心，通过 flutter_rust_bridge 异步调用，Rust 库随桌面包分发。新版只支持 Windows x64 与 macOS arm64 桌面应用，不附带 Node、WebView、本地 HTTP 服务或浏览器版；只读的 JSON 命令行 `token-lens-cli` 随包附带（[cli.md](cli.md)）。关闭窗口即退出，不增加托盘或后台常驻。选择整体重写是产品方向；资源占用是否下降需在统计迁移后用相同数据和测量口径确认。

实施顺序：D1 OpenAI RSS 基础预览 → D2 完整首批新闻来源 → D2.5 官方 API 变更来源、条目类型与来源内热度排序 → D3 统计核心、界面与适配器逐批迁移 → D4 数据副本验收和发行切换。每阶段结束停审。D1 的接口、缓存和失败语义见 [news.md](news.md)，D3 的兼容基线和子阶段见 [stats.md](stats.md)，开发入口见 [../../app/README.md](../../app/README.md)。D2.6 起新闻在程序开着时每 30 分钟自动刷新，启动时缓存过期就立即刷新一次，规则见 [news.md](news.md)「定时刷新」。

新旧版本使用独立目录；新版本不直接升级或双写旧版账本 `~/.token-lens`。真实数据切换需先备份、在副本升级、核对记录身份和计价、证明重复采集幂等，再由用户确认切换（D4 已按此完成）。公开价格估算与实际支出分开，后者不从 token 推算订阅付款。Skills 管理和多账户切换不属于 D1–D4。

新版 Windows 程序名为 `token-lens.exe`，产品名和窗口标题为 `Token Lens`；单实例互斥量为 `Local\TokenLens.Desktop`，激活时同时匹配 Flutter runner 类名 `FLUTTER_RUNNER_WIN32_WINDOW` 与标题，避免激活旧版窗口。macOS 应用名为 `Token Lens.app`，bundle id 为 `io.github.rumoii.token-lens`。默认数据目录为系统应用支持目录下的 `data`（Windows 为 `%APPDATA%\Token Lens\Token Lens\data`）；不自动读取或迁移旧新闻目录及 `~/.token-lens`。调试运行仍须显式设置 `TOKEN_LENS_PREVIEW_DATA_DIR`；该变量与日志根覆盖变量 `TOKEN_LENS_PREVIEW_HOME` 保持原名。

旧版桌面壳（W/M 路线，Node/React/wry）的构建与运行契约移到了 [../archive/legacy-desktop.md](../archive/legacy-desktop.md)。
