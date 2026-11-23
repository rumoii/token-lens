# 桌面应用（Windows、macOS）

## 重写决定（2026-11-05）

状态：D1、D2、D2.5、D2.6（新闻）、D3.1–D3.5（统计）和 D4（数据副本验收与切换）已完成。旧版 Node/React 工具在 v0.1.0 之前从仓库删除，删除前的最后一个提交打了标签 `legacy-node`。发布流程打 zip 包（见 [release.md](release.md)）；安装程序和 macOS 真机验收尚未排期。

采用 Flutter 界面 + Rust 核心，通过 flutter_rust_bridge 异步调用，Rust 库随桌面包分发。新版只支持 Windows x64 与 macOS arm64 桌面应用，不附带 Node、WebView、本地 HTTP 服务或浏览器版；只读的 JSON 命令行 `token-lens-cli` 随包附带（[cli.md](cli.md)）。关闭窗口即退出，不增加托盘或后台常驻。选择整体重写是产品方向；资源占用是否下降需在统计迁移后用相同数据和测量口径确认。

实施顺序：D1 OpenAI RSS 基础预览 → D2 完整首批新闻来源 → D2.5 官方 API 变更来源、条目类型与来源内热度排序 → D3 统计核心、界面与适配器逐批迁移 → D4 数据副本验收和发行切换。每阶段结束停审。D1 的接口、缓存和失败语义见 [news.md](news.md)，D3 的兼容基线和子阶段见 [stats.md](stats.md)，开发入口见 [../../app/README.md](../../app/README.md)。D2.6 起新闻在程序开着时每 30 分钟自动刷新，启动时缓存过期就立即刷新一次，规则见 [news.md](news.md)「定时刷新」。

新旧版本使用独立目录；新版本不直接升级或双写旧版账本 `~/.token-lens`。真实数据切换需先备份、在副本升级、核对记录身份和计价、证明重复采集幂等，再由用户确认切换（D4 已按此完成）。公开价格估算与实际支出分开，后者不从 token 推算订阅付款。Skills 管理和多账户切换不属于 D1–D4。

新版 Windows 程序名为 `token-lens.exe`，产品名和窗口标题为 `Token Lens`；单实例互斥量为 `Local\TokenLens.Desktop`，激活时同时匹配 Flutter runner 类名 `FLUTTER_RUNNER_WIN32_WINDOW` 与标题，避免激活旧版窗口。macOS 应用名为 `Token Lens.app`，bundle id 为 `io.github.rumoii.token-lens`。默认数据目录为系统应用支持目录下的 `data`（Windows 为 `%APPDATA%\Token Lens\Token Lens\data`）；不自动读取或迁移旧新闻目录及 `~/.token-lens`。调试运行仍须显式设置 `TOKEN_LENS_PREVIEW_DATA_DIR`；该变量与日志根覆盖变量 `TOKEN_LENS_PREVIEW_HOME` 保持原名。

旧版桌面壳（W/M 路线，Node/React/wry）的构建与运行契约移到了 [../archive/legacy-desktop.md](../archive/legacy-desktop.md)。

Windows 的首次引导默认选中「在桌面创建快捷方式」，也可从「价格与设置 → 外观与界面」创建或重建。`Token Lens.lnk` 指向当前运行的 `token-lens.exe`，工作目录和图标随 exe 的位置确定。同名快捷方式会被替换。桌面由 `SHGetKnownFolderPath(FOLDERID_Desktop)` 解析，支持系统重定向。预览运行时只在 `<TOKEN_LENS_PREVIEW_HOME>/Desktop` 创建快捷方式。快捷方式与首次同步并行，创建失败的详细信息记录在运行日志中。

「联网与更新」的价格表自动更新默认开启。完成首次引导后约 10 秒首次判断，之后每小时判断，自动请求间隔至少 24 小时，失败也计入间隔。上次尝试时间在未来也视为已满。「立即更新」和「重试」可随时检查。关闭开关时移除下载表并触发同步。预览运行以本机合成数据模拟请求结果。下载协议和定价顺序见 [定价与金额契约](pricing.md)。

总览和明细页头提供小窗入口（代码里仍叫 mini window）。已完成首次引导且有账本记录的桌面用户会在总览看见引导横幅。关闭横幅或成功进入小窗后，将 `miniHintDismissed: true` 保存到 `ui-preferences.json`。缺少该字段的旧偏好仍可显示横幅。

小窗标题栏的「缩成迷你模式」把窗口缩成约 36 DIP 高、最宽 240 DIP 的胶囊，显示今天的 token 和金额，始终置顶。单击、Enter 或空格展开回小窗，并恢复小窗原来的大小和置顶设置。按下后移动超过 4 DIP 才算拖动。Windows 上松手时，胶囊离工作区左边缘或右边缘不到 24 DIP，或者已经越过边缘，就贴到那一侧：那一侧没有相接的显示器时，胶囊收到屏幕外，只露出 26 DIP，悬停时滑出，离开约 400 ms 后收回；有相接的显示器时，只贴边、整条可见。上下边缘不贴。macOS 只在屏幕内拖动，不贴边。圆角、边框和阴影由系统绘制，Windows 10 上是直角。迷你模式的状态保存在 `ui-preferences.json` 的 `mini.pill`、`mini.pillBounds`、`mini.pillEdge`，旧版本读取时忽略这些字段。

迷你模式的窗口切换按顺序排队执行，用户操作不会因为正在调整胶囊宽度而丢失。排队的拖动开始前会再次确认主键仍按着，已经松开就放弃。运行日志用模块名 `mini-window` 记录每次切换的排队、开始、结束、耗时和合并次数；一次切换超过 5 秒还没结束时，写一条 WARN，带上还没返回的窗口平台方法。
