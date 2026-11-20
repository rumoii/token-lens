# 旧版桌面壳（W/M 路线）

本文记录旧版 Node/React/wry 桌面壳的需求、选型和打包协议，原是 `docs/development/desktop.md` 的后半部分。旧版已从仓库删除（标签 `legacy-node`），文中的路径和命令指向那时的代码，不适用于现在的 Flutter 应用。

## 已发布 W/M 路线

本文件是 [roadmap.md](../archive/roadmap.md) 阶段 W 的展开。交付形态与技术路线已定（见「选型」），本文记录已定需求、体积依据、落选候选、剩余待定项、现有代码对桌面化的约束和验收标准。

行号是 2026-10-21（`64368fa` 之后）的位置。

## 已定的需求

- Windows x64 与 macOS arm64（macOS 于 2026-11-03 加入，见「macOS（arm64）」）；Linux 未做。
- 双击图标打开窗口即可用，不需要终端、不需要手动开浏览器。
- 只有窗口：打开即采集一次，窗口开着时按现有 5 分钟间隔采集，关窗即退出。没有托盘、没有后台进程、没有开机自启。
- 数据目录仍是 `~/.token-lens`，与 CLI 共用账本。
- 交付形态是免安装的自解压单 exe，双击即用；体积口径以安装包为准，20–30MB 可接受，安装后体积不设限。
- 前置依赖：[ledger-trust.md](../archive/ledger-trust.md) 的 L2（去掉随 cwd 变化的扫描、CLI 采集加锁）必须先完成。

## 选型（2026-10-23 定）

选定路线是**零重写打包**：内核与前端保持原样，壳拉起打包内的官方 `node.exe`（v24 win-x64）作为子进程运行 `lens serve`，窗口加载 `http://127.0.0.1:<port>`。自解压 exe 首次运行解压到 `%LOCALAPPDATA%\token-lens-app\<版本>\` 并启动窗口，之后双击直接启动。安装后布局 `<root>/`：`token-lens.exe`（壳）、`node.exe`、`src/core/`、`dashboard/dist/`，保持 `DIST_DIR` 的相对关系（`server.js:19`）零改动。

体积依据：`node.exe` 93,915,464 字节，LZMA ultra（`7za -mx=9 -mfb=273 -md=64m -ms=on`）压缩后 21,764,228 字节；加源码、`dashboard/dist` 与自解压壳合计约 23MB，落在体积口径内。

落选与备选：

| 候选 | 安装包 | 安装后 | 结论 |
|---|---|---|---|
| 零重写 + 自建 slim Node（去 ICU、inspector） | 12–15MB | 62–65MB | 二期瘦身备选；需长期自建维护 Node，且先验证去 ICU 不破坏 Intl |
| Rust + Tauri 2 内核原生化 | 5–8MB | 9–13MB | 体积最优，但 6847 行内核变成与 CLI 并存的第二套账本实现，约 23–30 人日 |
| QuickJS + Go 宿主（JS 内核零改动 + shim） | 5–7MB | 11–15MB | 双宿主方案；shim 面窄，但先要尖峰验证 Intl 时区绑定、`node:sqlite` 语义与 GB 级日志性能 |
| .NET AOT + Photino | 4–7MB | 9–13MB | 弃：工期 33–43 人日最长，WebView2 × NativeAOT 兼容未验证 |
| Tauri 2 + 内置 node.exe / Electron | 35–45MB / 90–120MB | — | 弃：超体积口径 |

体积口径若收紧到 10MB 级，重启 Rust + Tauri 或 QuickJS 路线（后者先做尖峰验证）。

壳的实现载体定为 **Rust + wry**（2026-10-23 尖峰定）：wry/tao 最小原型 910KB，质感与扩展性由 Rust 生态承担；以 `windows_subsystem = "windows"` 构建，不弹控制台窗口。C++/WebView2 原型 148KB 但集成代码量大，Photino 因需另装 .NET SDK 弃。职责固定：单实例互斥量、Job Object 托管 `node.exe` 子进程（关窗或壳崩溃时一并结束）、内核就绪检测与加载/失败态、外链转系统浏览器。日志由内核的 `--desktop-logs` 写入 `<data-dir>/logs/` 并轮转。

不论壳用什么载体，安装新依赖前都要先向用户列出：装什么、装到哪、会不会留缓存。根 `package.json` 的 `dependencies` 必须保持 `{}`（[CONTRIBUTING.md](../../CONTRIBUTING.md)），桌面壳放独立目录（例如 `desktop/`，自带 `package.json` 或 `Cargo.toml`），与 `dashboard/` 同样处理。

## 现有代码对桌面化的约束

内核：

- 零运行时依赖，只用 Node 内置模块：`node:sqlite` 的 `DatabaseSync`（账本读写；6 个适配器用 `readOnly: true` 打开外部库，`db/legacy.js` 只读打开旧 `data.db`）、`node:zlib` 的 zstd（`src/core/adapters/_zstd.js`，codex 与 zed 用）、`fs.globSync`（`src/core/discovery.js`）。`engines.node` 是 `>=24.21.0`，仓库里没写为什么是这个版本。
- `serve`（`src/core/cli.js` `handleServe`）：先 `startServer(port)` 并输出就绪行；账本已有数据时随后在后台全量采集一次。采集期间 `last_run.status` 为 `running`，侧栏显示「正在同步」并轮询到结束后刷新；撞上采集锁只跳过这一次（日志 `[启动同步] 跳过`），服务照常运行。
- 端口：默认 3456，`src/core/http/port.js` 只在 `EADDRINUSE` 时顺延，最多 10 次，固定绑 `127.0.0.1`。`serve --strict-port` 只尝试指定端口，占用时 exit 1，不顺延。实际端口在 `ctx.meta.port`、控制台 banner 和 `TOKEN_LENS_READY` 行里。
- `DIST_DIR`（`server.js:19`）是相对源码文件的 `../../../dashboard/dist`。打包后的布局要么保持这个相对关系，要么改成可配置。
- API token 在 `<data-dir>/api-token`，由 `src/core/http/static.js` 注入每个 HTML 响应的 `<meta name="lens-api-token">`。
- `src/core/http/gate.js`：Host 必须是回环加端口；写请求的 `Origin` 必须是回环。**`tauri://`、`app://`、`file://` 和 `null` 都会被拒绝**，所以窗口应直接加载 `http://127.0.0.1:<port>`，而不是用自定义协议装载静态文件。
- 定时采集：`server.js` 里 5 分钟 `setInterval`（`unref`），关服务时清掉；`POST /api/v1/sync` 手动触发；都经 `runIngestion`，用 `<data-dir>/sync-lock.db` 跨进程互斥。
- `serve --desktop-logs` 把 stdout/stderr 同步写入 `<data-dir>/logs/kernel.log`，每个文件最多 5MiB，另保留 `.1`、`.2` 两份，合计最多 15MiB。控制台与管道输出仍保留。默认 CLI 不写日志文件。
- `process.exit(1)`（`cli.js`、`server.js`）与 `process.argv[1]` 入口判断（`server.js`）都是按 CLI 进程写的。桌面版把内核作为 `node.exe` 子进程运行，这些行为保持原样，退出语义由子进程承担。
- 没有关闭服务的 HTTP 路由；退出靠结束进程。

前端：

- `dashboard/src/main.jsx` 用 `createBrowserRouter`（history 模式），依赖服务端 SPA 回落，不能用 `file://` 加载。
- `dashboard/src/lib/v1.ts` 用 `window.location.origin` 拼 API 地址，token 从 meta 读，所以页面必须与 API 同源。
- 设置（主题、周期、数字单位、货币、语言、是否已引导）存在 localStorage，按 origin 隔离。**端口一变就是新 origin，设置全部丢失**，所以桌面壳应尽量固定端口，或把这些设置挪到服务端。
- 外链：`dashboard/src/pages/v1/SettingsPage.jsx:170` 的价格来源链接是 `target="_blank"`，桌面壳要把它交给系统浏览器打开。
- 唯一外联请求是 USD/CNY 汇率（`dashboard/src/lib/exchange-rate.ts`），只有点击「更新汇率」才联网；页面加载、后台同步与定时器不触发该请求，桌面版保持相同边界（[features.md](../archive/features.md) G14–G16）。
- `ErrorBoundary.jsx` 用 `window.location.reload()`，在 WebView 里可用。
- 设置页显示 `http://127.0.0.1:<port>` 与数据目录，文案为「只有这台电脑能打开」，适用于浏览器与桌面窗口。

## W1–W3 运行与打包协议

### 内核与壳

`bin/lens.js serve` 在监听成功、路由与鉴权完成初始化后，仅输出一次单行 JSON（没有 token）：

```text
TOKEN_LENS_READY {"port":3456,"data_dir":"C:\\path\\to\\data","pid":1234}
```

只有 `serve` 的 CLI 入口输出此行；直接调用 `startServer` 不输出。就绪行在启动补采之前输出，窗口不等采集完成就打开。就绪字段为整数 `port`、绝对路径字符串 `data_dir`、整数 `pid`。旧 CLI 消费者可忽略此行；桌面壳与内核随同一个包分发，不混用版本。

`desktop/src/runtime/windows.rs` 用 `CREATE_SUSPENDED | CREATE_NO_WINDOW` 创建 Node，再将它挂入带 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job，最后恢复执行。挂入失败时终止仍挂起的 Node。壳持有 Job 句柄，关窗显式关闭；壳被强制结束时由 Windows 关闭。`Local\\TokenLens.Desktop.v1` 命名互斥量覆盖解压到关窗，跨版本共享；第二次启动恢复并聚焦标题为 `Token Lens` 的窗口后退出。

启动命令为打包的 `node.exe <root>/bin/lens.js serve --port 3456 --strict-port --desktop-logs --data-dir <dir>`。数据目录遵循 `paths.js` 的默认目录及 `TOKEN_LENS_DATA_DIR` / `DB_PATH` 规则，冲突仍由内核拒绝。窗口先显示无网络的内联加载页；收到且核对端口、数据目录、子进程 PID 后才导航到回环页面。内核退出或 30 秒内未就绪时显示原因、端口提示及日志路径；超时会终止内核。窗口只允许固定回环 origin 和内联页，其他 HTTP(S) 导航与新窗口请求交给系统浏览器，拒绝页面启动其他协议或本地文件。

WebView2 用户数据单独放在 `<data-dir>/webview/`，使不同解压版本复用同一份 localStorage。Windows 必须已有 WebView2 Runtime。

### 自解压与构建

构建需要已安装的 Rust、缓存中的 Cargo 依赖、官方 Node v24 和已构建的 dashboard；不下载 Node、不安装前端依赖或外部打包工具。PowerShell 示例：

```powershell
$env:PATH = '<rust>\cargo\bin;' + $env:PATH
$env:TOKEN_LENS_NODE_EXE = '<node>\node.exe'
$env:TOKEN_LENS_DIST_DIR = '<repo>\dashboard\dist'
node desktop/build.mjs
```

`TOKEN_LENS_NODE_EXE` 缺省用 PATH 的 `node.exe`，校验版本以 `v24.` 开头；`TOKEN_LENS_DIST_DIR` 必填。Cargo 使用 `--offline --locked`。构建脚本仅收集壳、Node、`bin/`、`src/core/`、`dashboard/dist/`、package 元信息与许可证，不包含测试、specs 或 node_modules；拒绝链接输入。

`desktop/src/pack.rs` 用纯 Rust `lzma-rust2` 压缩，64MiB 字典、preset 9、nice_len 273。载荷格式为 `TLPL0001`、小端 u32 文件数，再重复小端 u32 路径字节数、小端 u64 文件字节数、UTF-8 相对路径、原始文件。单 exe 为壳 + LZMA 载荷 + JSON manifest + 小端 u32 manifest 字节数 + `TLENS001`。manifest 包含版本、压缩载荷 SHA-256、压缩与原始字节数；壳拒绝不支持的标记、越界路径、重复路径、截断和超限数据。

产物在 `desktop/dist/token-lens-<package-version>-<hash前12位>.exe`。脚本打印输入各部分、压缩载荷、壳、元信息和 exe 字节数，超过 **30,000,000 字节**即失败。`desktop/.cargo/config.toml` 将 Cargo 中间文件放到仓库已有的 `.tmp/desktop-target/`，使源码扫描器无需读取大型编译元数据；构建脚本通过 `cargo metadata` 获取实际位置。

首次启动校验压缩载荷哈希，解压到 `%LOCALAPPDATA%/token-lens-app/.<版本>-<pid>-<时间>/`，全部文件和长度校验成功后写入 `.complete`（完整载荷哈希），再原子改名为 `<版本>/`。安装布局保留 `DIST_DIR` 的相对关系。命名互斥量防止两个壳同时解压；后续启动检查完成标记与入口文件并复用目录，不重新解压。解压失败保留本次临时目录供排查；遇到不完整的目标目录明确报错，不覆盖已有文件。更新为新版本目录，旧版本不会自动删除。直接运行已解压的 `token-lens.exe` 也复用同一布局。

## macOS（arm64）

2026-11-03 定：只做 Apple Silicon；交付 `.dmg`，里面是标准 `.app`；只做 ad-hoc 签名，不公证。路线与 Windows 相同：壳拉起包内的官方 Node v24 darwin-arm64 跑 `lens serve`，窗口加载 `http://127.0.0.1:3456`，内核与前端不分平台。

### 布局

```text
Token Lens.app/Contents/
  Info.plist              bundle id io.github.rumoii.token-lens，LSMinimumSystemVersion 13.5
  MacOS/token-lens        壳
  MacOS/node              官方 node，保留官方签名与 JIT entitlements
  Resources/AppIcon.icns
  Resources/app/          bin/、src/core/、dashboard/dist/、package.json、LICENSE、NODE-LICENSE
```

`.app` 本身就是安装后的布局，不自解压；`Resources/app` 保持 `DIST_DIR` 的相对关系。`runtime/macos.rs` 的 `runtime_root()` 取 `<exe>/../Resources/app`，检查入口文件与 `MacOS/node`，缺了就提示从 dmg 重新拖入。最低系统 13.5 来自官方 Node v24 二进制的 `LC_BUILD_VERSION`（`minos 13.5`），更低的系统起不来内核。

### 壳

平台无关的窗口、就绪检测与失败页在 `desktop/src/main.rs`，数据目录在 `runtime/mod.rs`，平台部分在 `runtime/windows.rs` 与 `runtime/macos.rs`；`payload.rs` 只在 Windows 编译。

- 内核命令：`node <root>/bin/lens.js serve --port 3456 --strict-port --desktop-logs --exit-on-stdin-end --data-dir <dir>`，参数直接走 argv。
- 生命周期：macOS 没有 Job Object。壳一直持有 Node stdin 的写端，`--exit-on-stdin-end` 让内核在 stdin 读到 EOF 时退出。壳无论正常退出、崩溃还是被 `kill -9`，管道都由系统关闭，内核随之退出。关窗与 ⌘Q 时壳先关管道，2 秒内没退出再结束 Node。Windows 壳不传这个参数，行为不变。
- 单实例：对 `~/Library/Application Support/token-lens-app/instance.lock` 用 `File::try_lock`，拿不到锁就静默退出。双击已在运行的 `.app` 时 LaunchServices 直接激活已有实例。
- 菜单：「Token Lens → 退出 Token Lens」（⌘Q）与「编辑 → 撤销 / 重做 / 剪切 / 拷贝 / 粘贴 / 全选」。没有编辑菜单时 WKWebView 不响应 ⌘C/⌘V。
- 错误对话框用 `osascript` 的 `display alert`，消息经 argv 传入，不拼进脚本。外链只放行 http(s)，交给 `/usr/bin/open`。
- 数据目录规则与 Windows 相同，默认目录取 `HOME`。
- WebView 数据：wry 0.57.1 在 macOS 上用 `WKWebsiteDataStore.defaultDataStore`，不认 `WebContext` 的目录，所以数据目录里没有 `webview/`。看板设置存在 `~/Library/WebKit/io.github.rumoii.token-lens`，缓存在 `~/Library/Caches/io.github.rumoii.token-lens`（2026-11-03 实测）。bundle id 不变，跨版本保留设置。

### 构建

在 Mac 上执行：

```sh
npm ci --prefix dashboard
npm run dashboard:build
cargo fetch --locked --manifest-path desktop/Cargo.toml
TOKEN_LENS_DIST_DIR="$PWD/dashboard/dist" node desktop/build.mjs
```

`desktop/build.mjs` 与 Windows 共用 Node 版本检查、`cargo build --release --offline --locked` 和文件收集，之后交给 `desktop/macos.mjs`：

1. 校验 Node：`process.arch` 必须是 `arm64`，`otool -L` 只允许 `/usr/lib/` 与 `/System/` 下的库（Homebrew 的 node 链接 `/opt/homebrew` 下的库，拷进包后在别的机器上起不来）。`TOKEN_LENS_NODE_EXE` 缺省用 PATH 上的 `node`。
2. 在 Cargo 目标目录的 `bundle/macos/` 下组装 `.app`，用 `sips` 与 `iconutil` 从 `dashboard/public/icon-512.png` 生成图标。
3. 签名：`codesign --force --sign - --identifier io.github.rumoii.token-lens` 签整个 `.app`，不加 `--deep`，内嵌的 node 保留官方签名；再对 `.app` 与 node 分别跑 `codesign --verify --strict`。
4. `hdiutil create -format ULMO` 打成 dmg，卷里放 `.app` 和指向 `/Applications` 的软链接。
5. 产物是 `desktop/dist/token-lens-<package-version>-<输入哈希前12位>-macos-arm64.dmg`，哈希按文件名、长度和内容依次计算。脚本打印各部分字节数与 dmg 字节数。

体积：dmg 超过 **37,000,000 字节**即失败，且不复制到 `desktop/dist`。2026-11-03 用 Node v24.22.1 实测，同一组输入的 dmg 在 30,302,613 与 32,131,379 字节两档之间变化（hdiutil 输出不固定），上限取较大值上浮约 15%。其中 node 原始 122,545,856 字节，是体积的主体。

### 冒烟与 CI

`node desktop/smoke-macos.mjs <dmg>` 只读挂载 dmg，用临时 HOME 与 `TOKEN_LENS_DATA_DIR` 直接运行壳，依次检查：

- 就绪后只有一个内核子进程，且带 `--exit-on-stdin-end` 与临时数据目录；
- 第二次启动以 0 退出，内核不变；
- `kill -9` 壳后 5 秒内内核退出、3456 释放；
- 用 `NSRunningApplication terminate` 正常退出（与 ⌘Q 同一路径）后同样无残留；
- 3456 被占用时内核报错退出，壳停在失败页、不退出。

跑冒烟需要图形会话。GitHub 的 macOS runner 自带图形会话；远程 Mac 要在已登录用户的会话里运行，例如 `sudo launchctl asuser <uid> sudo -u <user> node desktop/smoke-macos.mjs <dmg>`。CI 的 `desktop-macos` job 在 `macos-15` 上构建 dmg 并跑冒烟。

### 分发

dmg 没有公证。2026-11-03 在 macOS 27.0 上实测，dmg 带着下载隔离属性时：

- 第一次打开弹出「未打开 "Token Lens"」，只有「完成」和「移到废纸篓」两个按钮。点「完成」后，到「系统设置 → 隐私与安全性」点「仍要打开」，之后这一份可以直接打开。
- 放行只对那一份程序有效。直接从挂载卷打开时，系统把 `.app` 转移到 `AppTranslocation` 临时路径下只读运行，`runtime_root()` 照常工作；之后再拖进「应用程序」，还要放行一次。
- 升级时把新版 `.app` 拖进「应用程序」覆盖旧版，新版本同样要放行一次（推断：新拷贝带着隔离属性，按上一条应同样被拦，未单独实测）。

## 通用要求

1. 单实例：第二次双击时聚焦已有窗口，不起第二个内核。
2. 关窗时可靠结束内核进程，包括壳崩溃的情况（Windows Job Object 或等价机制）。
3. 内核就绪前窗口显示加载态；内核启动失败时窗口显示原因和日志位置，而不是白屏。
4. 端口优先固定 3456；被占时的处理要明确（顺延会丢 localStorage 设置）。
5. 外链交给系统浏览器。
6. 日志写进 `<data-dir>/logs/`，按大小或日期轮转。
7. 自解压单 exe：首次运行解压到 `%LOCALAPPDATA%\token-lens-app\<版本>\` 并启动，之后双击直接启动；可选提供「创建桌面快捷方式」；不写注册表、无卸载器，更新即下载新版 exe。不签名时 SmartScreen 会警告，签名与否另议。
8. 文档：README 的安装与使用、`PRIVACY.md` 和 `SECURITY.md` 里「在浏览器里打开」「只监听回环」的表述按最终形态改写；CI 的 `desktop-windows` job 在代码改动的 PR 上于 `windows-2025` 构建 exe，并断言不超过 30,000,000 字节；`desktop-macos` job 在 `macos-15` 上构建 dmg 并跑冒烟（`.github/workflows/pr-checks.yml`）。

## 验收

- 在一台没装 Node 的 Windows 上，双击单个 exe，首次解压后直接打开窗口并看到数据，全程没有安装向导。
- 自解压 exe 体积 ≤30MB（目标 23MB 上下），构建产物带体积断言。
- 关窗后任务管理器里没有残留的内核进程。
- 同时开着 CLI `lens serve` 或在跑 `lens collect` 时，桌面版的采集得到锁冲突而不是并发写。
- 页面加载、后台采集都不产生外部请求（沿用 C6 的验证方式）。
