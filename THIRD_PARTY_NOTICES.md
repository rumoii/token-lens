# 第三方声明

## 核心零依赖

根 `package.json` 的 `dependencies` 为空：Node CLI（`bin/lens.js` → `src/core/`）只使用 Node 内置模块（`node:sqlite`、`node:http`、`node:crypto`、`node:zlib` 等），没有任何第三方运行时依赖。

本项目按 MIT 许可发布，Copyright (c) 2026 rumoii。

## 仪表盘运行时依赖

以下为 `dashboard/package.json` 中 `dependencies` 的解析版本，以 `dashboard/package-lock.json` 为准：

| 组件 | 版本 | 许可证 | 链接 |
| --- | --- | --- | --- |
| @base-ui/react | 1.8.0 | MIT | https://www.npmjs.com/package/@base-ui/react |
| @dnd-kit/core | 6.3.1 | MIT | https://www.npmjs.com/package/@dnd-kit/core |
| @dnd-kit/modifiers | 7.0.0 | MIT | https://www.npmjs.com/package/@dnd-kit/modifiers |
| @dnd-kit/sortable | 8.0.0 | MIT | https://www.npmjs.com/package/@dnd-kit/sortable |
| @dnd-kit/utilities | 3.2.2 | MIT | https://www.npmjs.com/package/@dnd-kit/utilities |
| @fontsource/geist | 5.3.0 | OFL-1.1 | https://www.npmjs.com/package/@fontsource/geist |
| @fontsource/geist-mono | 5.3.0 | OFL-1.1 | https://www.npmjs.com/package/@fontsource/geist-mono |
| clsx | 2.1.1 | MIT | https://www.npmjs.com/package/clsx |
| date-fns | 4.4.0 | MIT | https://www.npmjs.com/package/date-fns |
| lucide-react | 1.47.0 | ISC | https://www.npmjs.com/package/lucide-react |
| motion | 12.43.0 | MIT | https://www.npmjs.com/package/motion |
| react | 18.3.1 | MIT | https://www.npmjs.com/package/react |
| react-day-picker | 9.14.0 | MIT | https://www.npmjs.com/package/react-day-picker |
| react-dom | 18.3.1 | MIT | https://www.npmjs.com/package/react-dom |
| react-router-dom | 7.18.4 | MIT | https://www.npmjs.com/package/react-router-dom |
| tailwind-merge | 3.7.0 | MIT | https://www.npmjs.com/package/tailwind-merge |

字体包 `@fontsource/geist` 与 `@fontsource/geist-mono`（OFL-1.1）随构建产物分发，其许可条款与 MIT 不同。

## 开发与构建工具

`dashboard/package.json` 的 `devDependencies`（Vite、TypeScript、ESLint、Vitest、Tailwind CSS 等）仅用于开发、测试与构建，不随运行时分发；各包许可以其包内声明为准，完整清单见 [dashboard/package.json](dashboard/package.json) 与 [dashboard/package-lock.json](dashboard/package-lock.json)。

## 许可证全文

- MIT：本仓库 [LICENSE](LICENSE)。
- OFL-1.1：https://openfontlicense.org
- ISC：https://opensource.org/licenses/ISC


## 工具图标来源

图标来自固定发布包 `@lobehub/icons-static-svg@1.102.0`，未安装为项目依赖。来源：[LobeHub/lobe-icons](https://github.com/lobehub/lobe-icons)。

导入时保留几何数据，统一尺寸并在 SVG metadata 中登记来源；单色图使用中性色，Pi 在既有深底磁贴上使用浅色。包中没有对应工具图标的 ZCode 使用本项目绘制的中性首字母方块。

| 文件 | 来源与版本 | 许可 |
| --- | --- | --- |
| claude-code.svg | @lobehub/icons-static-svg 1.102.0, icons/claudecode-color.svg | MIT |
| cline.svg | @lobehub/icons-static-svg 1.102.0, icons/cline.svg | MIT |
| codebuddy.svg | @lobehub/icons-static-svg 1.102.0, icons/codebuddy-color.svg | MIT |
| codex.svg | @lobehub/icons-static-svg 1.102.0, icons/codex-color.svg | MIT |
| copilot.svg | @lobehub/icons-static-svg 1.102.0, icons/copilot-color.svg | MIT |
| cursor.svg | @lobehub/icons-static-svg 1.102.0, icons/cursor.svg | MIT |
| deepseek.svg | @lobehub/icons-static-svg 1.102.0, icons/deepseek-color.svg | MIT |
| gemini.svg | @lobehub/icons-static-svg 1.102.0, icons/geminicli-color.svg | MIT |
| grok.svg | @lobehub/icons-static-svg 1.102.0, icons/grok.svg | MIT |
| hermes.svg | @lobehub/icons-static-svg 1.102.0, icons/hermesagent.svg | MIT |
| kimi.svg | @lobehub/icons-static-svg 1.102.0, icons/kimi-color.svg | MIT |
| openclaw.svg | @lobehub/icons-static-svg 1.102.0, icons/openclaw-color.svg | MIT |
| opencode.svg | @lobehub/icons-static-svg 1.102.0, icons/opencode.svg | MIT |
| pi.svg | @lobehub/icons-static-svg 1.102.0, icons/pi.svg | MIT |
| mimo.svg | @lobehub/icons-static-svg 1.102.0, icons/xiaomimimo.svg | MIT |
| zcode.svg | 本项目绘制：ZCode 首字母方块 | MIT（本项目） |

### LobeHub 图标许可

MIT License  Copyright (c) 2023 LobeHub  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

<!-- desktop-dependencies:generated -->
## 桌面应用的 Dart/Flutter 依赖

由 [scripts/generate-desktop-notices.dart](scripts/generate-desktop-notices.dart) 根据 `app/pubspec.lock`、已解析的 Pub 缓存包 `pubspec.yaml` / LICENSE 和 Flutter SDK 生成。SDK：Flutter 3.47.9、Dart 3.13.7。保留完整生产依赖声明图作为分发清单上界，包含条件导入、其他平台实现及工具传递项；不是 AOT tree-shaking 后的逐符号清单。SDK 的 0.0.0 是锁文件占位版本。

| 组件 | 版本 | 许可证 | 口径 / 平台 | 链接 |
| --- | --- | --- | --- | --- |
| args | 2.7.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/args/versions/2.7.0/license |
| async | 2.13.1 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/async/versions/2.13.1/license |
| build_cli_annotations | 2.1.1 | MIT | 运行时声明图上界 | https://pub.dev/packages/build_cli_annotations/versions/2.1.1/license |
| characters | 1.4.1 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/characters/versions/1.4.1/license |
| code_assets | 1.2.1 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/code_assets/versions/1.2.1/license |
| collection | 1.19.1 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/collection/versions/1.19.1/license |
| crypto | 3.0.8 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/crypto/versions/3.0.8/license |
| ffi | 2.2.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/ffi/versions/2.2.0/license |
| flutter | 0.0.0（Flutter 3.47.9） | BSD-3-Clause | 运行时声明图上界 | https://github.com/flutter/flutter/tree/3.47.9 |
| flutter_rust_bridge | 2.13.0 | MIT | 运行时声明图上界 | https://pub.dev/packages/flutter_rust_bridge/versions/2.13.0/license |
| flutter_web_plugins | 0.0.0（Flutter 3.47.9） | BSD-3-Clause | 运行时声明图上界 | https://github.com/flutter/flutter/tree/3.47.9 |
| hooks | 2.0.2 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/hooks/versions/2.0.2/license |
| jni | 1.1.2 | BSD-3-Clause | 运行时声明图上界；插件 linux/windows/android | https://pub.dev/packages/jni/versions/1.1.2/license |
| jni_flutter | 1.0.4+1 | BSD-3-Clause | 运行时声明图上界；插件 android | https://pub.dev/packages/jni_flutter/versions/1.0.4+1/license |
| jni_util | 1.0.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/jni_util/versions/1.0.0/license |
| logging | 1.3.0 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/logging/versions/1.3.0/license |
| material_color_utilities | 0.13.0 | Apache-2.0 | 运行时声明图上界 | https://pub.dev/packages/material_color_utilities/versions/0.13.0/license |
| meta | 1.18.3 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/meta/versions/1.18.3/license |
| objective_c | 9.5.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/objective_c/versions/9.5.0/license |
| package_config | 3.0.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/package_config/versions/3.0.0/license |
| path | 1.9.1 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/path/versions/1.9.1/license |
| path_provider | 2.1.6 | BSD-3-Clause | 运行时声明图上界；插件 android/ios/linux/macos/windows | https://pub.dev/packages/path_provider/versions/2.1.6/license |
| path_provider_android | 2.3.1 | BSD-3-Clause | 运行时声明图上界；插件 android | https://pub.dev/packages/path_provider_android/versions/2.3.1/license |
| path_provider_foundation | 2.6.0 | BSD-3-Clause | 运行时声明图上界；插件 ios/macos | https://pub.dev/packages/path_provider_foundation/versions/2.6.0/license |
| path_provider_linux | 2.2.2 | BSD-3-Clause | 运行时声明图上界；插件 linux | https://pub.dev/packages/path_provider_linux/versions/2.2.2/license |
| path_provider_platform_interface | 2.1.3 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/path_provider_platform_interface/versions/2.1.3/license |
| path_provider_windows | 2.3.0 | BSD-3-Clause | 运行时声明图上界；插件 windows | https://pub.dev/packages/path_provider_windows/versions/2.3.0/license |
| platform | 3.2.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/platform/versions/3.2.0/license |
| plugin_platform_interface | 2.1.8 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/plugin_platform_interface/versions/2.1.8/license |
| pub_semver | 2.2.1 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/pub_semver/versions/2.2.1/license |
| record_use | 0.6.0 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/record_use/versions/0.6.0/license |
| sky_engine | 0.0.0（Flutter 3.47.9） | 多许可证（Flutter Engine 许可合集） | 运行时声明图上界 | https://github.com/flutter/flutter/tree/3.47.9 |
| source_span | 1.10.2 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/source_span/versions/1.10.2/license |
| string_scanner | 1.4.1 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/string_scanner/versions/1.4.1/license |
| term_glyph | 1.2.2 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/term_glyph/versions/1.2.2/license |
| url_launcher | 6.3.3 | BSD-3-Clause | 运行时声明图上界；插件 android/ios/linux/macos/web/windows | https://pub.dev/packages/url_launcher/versions/6.3.3/license |
| url_launcher_android | 6.3.33 | BSD-3-Clause | 运行时声明图上界；插件 android | https://pub.dev/packages/url_launcher_android/versions/6.3.33/license |
| url_launcher_ios | 6.4.2 | BSD-3-Clause | 运行时声明图上界；插件 ios | https://pub.dev/packages/url_launcher_ios/versions/6.4.2/license |
| url_launcher_linux | 3.2.3 | BSD-3-Clause | 运行时声明图上界；插件 linux | https://pub.dev/packages/url_launcher_linux/versions/3.2.3/license |
| url_launcher_macos | 3.2.6 | BSD-3-Clause | 运行时声明图上界；插件 macos | https://pub.dev/packages/url_launcher_macos/versions/3.2.6/license |
| url_launcher_platform_interface | 2.3.2 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/url_launcher_platform_interface/versions/2.3.2/license |
| url_launcher_web | 2.4.3 | BSD-3-Clause | 运行时声明图上界；插件 web | https://pub.dev/packages/url_launcher_web/versions/2.4.3/license |
| url_launcher_windows | 3.1.6 | BSD-3-Clause | 运行时声明图上界；插件 windows | https://pub.dev/packages/url_launcher_windows/versions/3.1.6/license |
| vector_math | 2.4.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/vector_math/versions/2.4.0/license |
| web | 1.1.2 | BSD-3-Clause | 运行时 / 构建声明图共用 | https://pub.dev/packages/web/versions/1.1.2/license |
| xdg_directories | 1.1.0 | BSD-3-Clause | 运行时声明图上界 | https://pub.dev/packages/xdg_directories/versions/1.1.0/license |
| yaml | 3.1.4 | MIT | 运行时 / 构建声明图共用 | https://pub.dev/packages/yaml/versions/3.1.4/license |

### Dart 开发与构建依赖（不作为运行时依赖计入）

应用的 `hook/build.dart` 使用 flutter_rust_bridge_hooks；其独有传递依赖标为仅构建，其余仅开发/测试项也单列。生产声明图与构建图共用的包保守列在上表。Flutter Engine 的聚合许可由 SDK 的 sky_engine/license 提供，发布目录内的 `data/flutter_assets/NOTICES.Z` 保留 Flutter 自动收集的许可全文；macOS 对应 `.app` 内的 Flutter assets。引擎合集包含多种许可证。

| 组件 | 版本 | 许可证 | 口径 / 平台 | 链接 |
| --- | --- | --- | --- | --- |
| boolean_selector | 2.1.2 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/boolean_selector/versions/2.1.2/license |
| clock | 1.1.3 | Apache-2.0 | 仅开发 / 测试 | https://pub.dev/packages/clock/versions/1.1.3/license |
| fake_async | 1.3.3 | Apache-2.0 | 仅开发 / 测试 | https://pub.dev/packages/fake_async/versions/1.3.3/license |
| flutter_lints | 6.0.0 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/flutter_lints/versions/6.0.0/license |
| flutter_rust_bridge_hooks | 2.13.0 | MIT | 仅构建 hook | https://pub.dev/packages/flutter_rust_bridge_hooks/versions/2.13.0/license |
| flutter_test | 0.0.0（Flutter 3.47.9） | BSD-3-Clause | 仅开发 / 测试 | https://github.com/flutter/flutter/tree/3.47.9 |
| leak_tracker | 11.0.2 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/leak_tracker/versions/11.0.2/license |
| leak_tracker_flutter_testing | 3.0.10 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/leak_tracker_flutter_testing/versions/3.0.10/license |
| leak_tracker_testing | 3.0.2 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/leak_tracker_testing/versions/3.0.2/license |
| lints | 6.1.0 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/lints/versions/6.1.0/license |
| matcher | 0.12.20 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/matcher/versions/0.12.20/license |
| native_toolchain_rust | 1.0.4+0 | MIT | 仅构建 hook | https://pub.dev/packages/native_toolchain_rust/versions/1.0.4+0/license |
| petitparser | 7.0.2 | MIT | 仅构建 hook | https://pub.dev/packages/petitparser/versions/7.0.2/license |
| stack_trace | 1.12.2 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/stack_trace/versions/1.12.2/license |
| stream_channel | 2.1.4 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/stream_channel/versions/2.1.4/license |
| test_api | 0.7.12 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/test_api/versions/0.7.12/license |
| toml | 0.18.0 | MIT | 仅构建 hook | https://pub.dev/packages/toml/versions/0.18.0/license |
| vm_service | 15.4.0 | BSD-3-Clause | 仅开发 / 测试 | https://pub.dev/packages/vm_service/versions/15.4.0/license |

## 桌面应用的 Rust 依赖

依据 `cargo metadata --locked --offline --filter-platform <target>`，分别遍历 Windows x64（x86_64-pc-windows-msvc）和 macOS arm64（aarch64-apple-darwin）的已启用 normal 依赖。build 边与 proc-macro 及其传递依赖单列；dev 边排除。两类共用包仍列在运行时表。许可证表达式保留 Cargo metadata 原文，缺省表达式时读取包的 license_file；不替双重许可包作选证决定。版本各自列出，不合并同名不同版本；平台按目标依赖图标注，未按最终链接器消除的符号裁剪。

| 组件 | 版本 | 许可证 | 口径 / 平台 | 链接 |
| --- | --- | --- | --- | --- |
| addr2line | 0.27.1 | Apache-2.0 OR MIT | 运行时；macOS arm64 | https://crates.io/crates/addr2line/0.27.1 |
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/adler2/2.0.1 |
| allo-isolate | 0.1.27 | Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/allo-isolate/0.1.27 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/anyhow/1.0.104 |
| async-compression | 0.4.52 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/async-compression/0.4.52 |
| atomic | 0.5.3 | Apache-2.0/MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/atomic/0.5.3 |
| atomic-waker | 1.1.2 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/atomic-waker/1.1.2 |
| backtrace | 0.3.77 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/backtrace/0.3.77 |
| base64 | 0.22.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/base64/0.22.1 |
| base64 | 0.23.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/base64/0.23.1 |
| bitflags | 2.13.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/bitflags/2.13.2 |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/block-buffer/0.10.4 |
| byteorder | 1.5.0 | Unlicense OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/byteorder/1.5.0 |
| bytes | 1.12.1 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/bytes/1.12.1 |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/cfg-if/1.0.5 |
| chacha20 | 0.10.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/chacha20/0.10.2 |
| chrono | 0.4.45 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/chrono/0.4.45 |
| compression-codecs | 0.4.47 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/compression-codecs/0.4.47 |
| compression-core | 0.4.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/compression-core/0.4.34 |
| core-foundation-sys | 0.8.7 | MIT OR Apache-2.0 | 运行时；macOS arm64 | https://crates.io/crates/core-foundation-sys/0.8.7 |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/cpufeatures/0.2.17 |
| cpufeatures | 0.3.1 | MIT OR Apache-2.0 | 运行时；Windows x64 | https://crates.io/crates/cpufeatures/0.3.1 |
| crc32fast | 1.5.4 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/crc32fast/1.5.4 |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/crypto-common/0.1.7 |
| cssparser | 0.35.0 | MPL-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/cssparser/0.35.0 |
| dart-sys | 4.1.5 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/dart-sys/4.1.5 |
| dashmap | 5.5.3 | MIT | 运行时；macOS arm64 | https://crates.io/crates/dashmap/5.5.3 |
| derive_more | 2.1.1 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/derive_more/2.1.1 |
| digest | 0.10.7 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/digest/0.10.7 |
| dtoa | 1.0.11 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/dtoa/1.0.11 |
| dtoa-short | 0.3.5 | MPL-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/dtoa-short/0.3.5 |
| ego-tree | 0.10.0 | ISC | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/ego-tree/0.10.0 |
| errno | 0.3.14 | MIT OR Apache-2.0 | 运行时；macOS arm64 | https://crates.io/crates/errno/0.3.14 |
| fallible-iterator | 0.3.0 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/fallible-iterator/0.3.0 |
| fallible-streaming-iterator | 0.1.9 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/fallible-streaming-iterator/0.1.9 |
| fastrand | 2.5.0 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/fastrand/2.5.0 |
| flate2 | 1.1.10 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/flate2/1.1.10 |
| flutter_rust_bridge | 2.13.0 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/flutter_rust_bridge/2.13.0 |
| foldhash | 0.2.0 | Zlib | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/foldhash/0.2.0 |
| form_urlencoded | 1.2.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/form_urlencoded/1.2.2 |
| fs2 | 0.4.3 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/fs2/0.4.3 |
| futf | 0.1.5 | MIT / Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futf/0.1.5 |
| futures | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures/0.3.34 |
| futures-channel | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-channel/0.3.34 |
| futures-core | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-core/0.3.34 |
| futures-executor | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-executor/0.3.34 |
| futures-io | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-io/0.3.34 |
| futures-sink | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-sink/0.3.34 |
| futures-task | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-task/0.3.34 |
| futures-util | 0.3.34 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/futures-util/0.3.34 |
| fxhash | 0.2.1 | Apache-2.0/MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/fxhash/0.2.1 |
| generic-array | 0.14.7 | MIT | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/generic-array/0.14.7 |
| getopts | 0.2.24 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/getopts/0.2.24 |
| getrandom | 0.2.17 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/getrandom/0.2.17 |
| getrandom | 0.4.3 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/getrandom/0.4.3 |
| gimli | 0.34.0 | MIT OR Apache-2.0 | 运行时；macOS arm64 | https://crates.io/crates/gimli/0.34.0 |
| hashbrown | 0.14.5 | MIT OR Apache-2.0 | 运行时；macOS arm64 | https://crates.io/crates/hashbrown/0.14.5 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/hashbrown/0.17.1 |
| hashlink | 0.12.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/hashlink/0.12.2 |
| html5ever | 0.35.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/html5ever/0.35.0 |
| http | 1.5.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/http/1.5.0 |
| http-body | 1.1.0 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/http-body/1.1.0 |
| http-body-util | 0.1.5 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/http-body-util/0.1.5 |
| httparse | 1.10.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/httparse/1.10.1 |
| hyper | 1.12.0 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/hyper/1.12.0 |
| hyper-rustls | 0.27.10 | Apache-2.0 OR ISC OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/hyper-rustls/0.27.10 |
| hyper-util | 0.1.21 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/hyper-util/0.1.21 |
| iana-time-zone | 0.1.65 | MIT OR Apache-2.0 | 运行时；macOS arm64 | https://crates.io/crates/iana-time-zone/0.1.65 |
| icu_collections | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_collections/2.4.0 |
| icu_locale_core | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_locale_core/2.4.0 |
| icu_normalizer | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_normalizer/2.4.0 |
| icu_normalizer_data | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_normalizer_data/2.4.0 |
| icu_properties | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_properties/2.4.0 |
| icu_properties_data | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_properties_data/2.4.0 |
| icu_provider | 2.4.0 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/icu_provider/2.4.0 |
| idna | 1.1.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/idna/1.1.0 |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/idna_adapter/1.2.2 |
| ipnet | 2.12.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/ipnet/2.12.2 |
| itoa | 1.0.18 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/itoa/1.0.18 |
| lazy_static | 1.5.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/lazy_static/1.5.1 |
| libc | 0.2.191 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/libc/0.2.191 |
| libsqlite3-sys | 0.38.2 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/libsqlite3-sys/0.38.2 |
| litemap | 0.8.3 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/litemap/0.8.3 |
| lock_api | 0.4.14 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/lock_api/0.4.14 |
| log | 0.4.35 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/log/0.4.35 |
| lru-slab | 0.1.3 | MIT OR Apache-2.0 OR Zlib | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/lru-slab/0.1.3 |
| mac | 0.1.1 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/mac/0.1.1 |
| markup5ever | 0.35.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/markup5ever/0.35.0 |
| memchr | 2.8.3 | Unlicense OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/memchr/2.8.3 |
| miniz_oxide | 0.9.1 | MIT OR Zlib OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/miniz_oxide/0.9.1 |
| mio | 1.2.4 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/mio/1.2.4 |
| new_debug_unreachable | 1.0.6 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/new_debug_unreachable/1.0.6 |
| num-traits | 0.2.19 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/num-traits/0.2.19 |
| num_cpus | 1.17.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/num_cpus/1.17.0 |
| object | 0.40.0 | Apache-2.0 OR MIT | 运行时；macOS arm64 | https://crates.io/crates/object/0.40.0 |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/once_cell/1.21.4 |
| oslog | 0.2.0 | MIT | 运行时；macOS arm64 | https://crates.io/crates/oslog/0.2.0 |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/parking_lot/0.12.5 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/parking_lot_core/0.9.12 |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/percent-encoding/2.3.2 |
| phf | 0.11.3 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/phf/0.11.3 |
| phf_shared | 0.11.3 | MIT | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/phf_shared/0.11.3 |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/pin-project-lite/0.2.17 |
| portable-atomic | 1.15.0 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/portable-atomic/1.15.0 |
| potential_utf | 0.1.6 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/potential_utf/0.1.6 |
| precomputed-hash | 0.1.1 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/precomputed-hash/0.1.1 |
| quinn | 0.11.12 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/quinn/0.11.12 |
| quinn-proto | 0.11.19 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/quinn-proto/0.11.19 |
| quinn-udp | 0.5.16 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/quinn-udp/0.5.16 |
| rand | 0.10.3 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rand/0.10.3 |
| rand_core | 0.10.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rand_core/0.10.1 |
| rand_pcg | 0.10.2 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rand_pcg/0.10.2 |
| reqwest | 0.12.28 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/reqwest/0.12.28 |
| ring | 0.17.14 | Apache-2.0 AND ISC | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/ring/0.17.14 |
| roxmltree | 0.20.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/roxmltree/0.20.0 |
| rusqlite | 0.40.2 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rusqlite/0.40.2 |
| rustc-demangle | 0.1.28 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rustc-demangle/0.1.28 |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rustc-hash/2.1.3 |
| rustix | 1.1.6 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | 运行时；macOS arm64 | https://crates.io/crates/rustix/1.1.6 |
| rustls | 0.23.46 | Apache-2.0 OR ISC OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rustls/0.23.46 |
| rustls-pki-types | 1.15.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rustls-pki-types/1.15.1 |
| rustls-webpki | 0.103.16 | ISC | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/rustls-webpki/0.103.16 |
| ruzstd | 0.9.0 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/ruzstd/0.9.0 |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/ryu/1.0.23 |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/scopeguard/1.2.0 |
| scraper | 0.24.0 | ISC | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/scraper/0.24.0 |
| selectors | 0.31.0 | MPL-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/selectors/0.31.0 |
| serde | 1.0.229 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/serde/1.0.229 |
| serde_core | 1.0.229 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/serde_core/1.0.229 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/serde_json/1.0.154 |
| serde_urlencoded | 0.7.1 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/serde_urlencoded/0.7.1 |
| servo_arc | 0.4.3 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/servo_arc/0.4.3 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/sha2/0.10.9 |
| simd-adler32 | 0.3.10 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/simd-adler32/0.3.10 |
| siphasher | 1.0.4 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/siphasher/1.0.4 |
| slab | 0.4.12 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/slab/0.4.12 |
| smallvec | 1.16.4 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/smallvec/1.16.4 |
| socket2 | 0.6.5 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/socket2/0.6.5 |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/stable_deref_trait/1.2.1 |
| string_cache | 0.8.9 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/string_cache/0.8.9 |
| subtle | 2.6.1 | BSD-3-Clause | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/subtle/2.6.1 |
| sync_wrapper | 1.0.2 | Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/sync_wrapper/1.0.2 |
| tempfile | 3.27.0 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tempfile/3.27.0 |
| tendril | 0.4.3 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tendril/0.4.3 |
| thiserror | 2.0.21 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/thiserror/2.0.21 |
| threadpool | 1.8.1 | MIT/Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/threadpool/1.8.1 |
| tinystr | 0.8.5 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tinystr/0.8.5 |
| tinyvec | 1.13.3 | Zlib OR Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tinyvec/1.13.3 |
| tokio | 1.54.1 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tokio/1.54.1 |
| tokio-rustls | 0.26.6 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tokio-rustls/0.26.6 |
| tokio-util | 0.7.20 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tokio-util/0.7.20 |
| tower | 0.5.3 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tower/0.5.3 |
| tower-http | 0.6.11 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tower-http/0.6.11 |
| tower-layer | 0.3.3 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tower-layer/0.3.3 |
| tower-service | 0.3.3 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tower-service/0.3.3 |
| tracing | 0.1.44 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tracing/0.1.44 |
| tracing-core | 0.1.36 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/tracing-core/0.1.36 |
| try-lock | 0.2.5 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/try-lock/0.2.5 |
| twox-hash | 2.1.5 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/twox-hash/2.1.5 |
| typenum | 1.20.1 | MIT OR Apache-2.0 | 运行时 / 构建共用；Windows x64、macOS arm64 | https://crates.io/crates/typenum/1.20.1 |
| unicode-width | 0.2.3 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/unicode-width/0.2.3 |
| untrusted | 0.9.0 | ISC | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/untrusted/0.9.0 |
| url | 2.5.8 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/url/2.5.8 |
| utf-8 | 0.7.6 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/utf-8/0.7.6 |
| utf8_iter | 1.1.0 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/utf8_iter/1.1.0 |
| utf_types | 1.0.0 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/utf_types/1.0.0 |
| want | 0.3.2 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/want/0.3.2 |
| web_atoms | 0.1.3 | MIT OR Apache-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/web_atoms/0.1.3 |
| webpki-roots | 1.0.11 | CDLA-Permissive-2.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/webpki-roots/1.0.11 |
| winapi | 0.3.9 | MIT/Apache-2.0 | 运行时；Windows x64 | https://crates.io/crates/winapi/0.3.9 |
| windows-link | 0.2.1 | MIT OR Apache-2.0 | 运行时；Windows x64 | https://crates.io/crates/windows-link/0.2.1 |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 | 运行时；Windows x64 | https://crates.io/crates/windows-sys/0.61.2 |
| writeable | 0.6.4 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/writeable/0.6.4 |
| yoke | 0.8.4 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/yoke/0.8.4 |
| zerofrom | 0.1.8 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zerofrom/0.1.8 |
| zeroize | 1.9.1 | Apache-2.0 OR MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zeroize/1.9.1 |
| zerotrie | 0.2.5 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zerotrie/0.2.5 |
| zerovec | 0.11.9 | Unicode-3.0 | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zerovec/0.11.9 |
| zlib-rs | 0.6.8 | Zlib | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zlib-rs/0.6.8 |
| zmij | 1.0.23 | MIT | 运行时；Windows x64、macOS arm64 | https://crates.io/crates/zmij/1.0.23 |

### Rust 构建依赖与 proc-macro（不作为运行时依赖计入）

| 组件 | 版本 | 许可证 | 口径 / 平台 | 链接 |
| --- | --- | --- | --- | --- |
| autocfg | 1.5.1 | Apache-2.0 OR MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/autocfg/1.5.1 |
| build-target | 0.4.0 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/build-target/0.4.0 |
| cc | 1.11.0 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/cc/1.11.0 |
| cfg_aliases | 0.2.2 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/cfg_aliases/0.2.2 |
| cssparser-macros | 0.6.1 | MPL-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/cssparser-macros/0.6.1 |
| delegate-attr | 0.3.1 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/delegate-attr/0.3.1 |
| derive_more-impl | 2.1.1 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/derive_more-impl/2.1.1 |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/displaydoc/0.2.7 |
| find-msvc-tools | 0.1.15 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/find-msvc-tools/0.1.15 |
| flutter_rust_bridge_macros | 2.13.0 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/flutter_rust_bridge_macros/2.13.0 |
| futures-macro | 0.3.34 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/futures-macro/0.3.34 |
| hex | 0.4.3 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/hex/0.4.3 |
| match_token | 0.35.0 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/match_token/0.35.0 |
| md-5 | 0.10.6 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/md-5/0.10.6 |
| phf_codegen | 0.11.3 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/phf_codegen/0.11.3 |
| phf_generator | 0.11.3 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/phf_generator/0.11.3 |
| phf_macros | 0.11.3 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/phf_macros/0.11.3 |
| pkg-config | 0.3.34 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/pkg-config/0.3.34 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/proc-macro2/1.0.107 |
| quote | 1.0.47 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/quote/1.0.47 |
| rand | 0.8.8 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/rand/0.8.8 |
| rand_core | 0.6.4 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/rand_core/0.6.4 |
| rustc_version | 0.4.1 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/rustc_version/0.4.1 |
| semver | 1.0.28 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/semver/1.0.28 |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/serde_derive/1.0.229 |
| shlex | 2.0.1 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/shlex/2.0.1 |
| string_cache_codegen | 0.5.4 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/string_cache_codegen/0.5.4 |
| syn | 2.0.119 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/syn/2.0.119 |
| syn | 3.0.9 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/syn/3.0.9 |
| synstructure | 0.14.0 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/synstructure/0.14.0 |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/thiserror-impl/2.0.21 |
| tokio-macros | 2.7.2 | MIT | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/tokio-macros/2.7.2 |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/unicode-ident/1.0.27 |
| vcpkg | 0.2.15 | MIT/Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/vcpkg/0.2.15 |
| version_check | 0.9.5 | MIT/Apache-2.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/version_check/0.9.5 |
| yoke-derive | 0.8.4 | Unicode-3.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/yoke-derive/0.8.4 |
| zerofrom-derive | 0.1.8 | Unicode-3.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/zerofrom-derive/0.1.8 |
| zerovec-derive | 0.11.7 | Unicode-3.0 | 仅构建 / proc-macro；Windows x64、macOS arm64 | https://crates.io/crates/zerovec-derive/0.11.7 |

### 更新清单

先使用项目已有 Flutter/Pub 和 Cargo 缓存完成锁定依赖解析，再在仓库根运行：

```sh
dart --packages=app/.dart_tool/package_config.json scripts/generate-desktop-notices.dart
dart --packages=app/.dart_tool/package_config.json scripts/generate-desktop-notices.dart --check
```

脚本不安装工具、不解析新版本，Cargo 始终 locked/offline；缓存缺失或许可证无法识别时失败。只替换本生成标记之后的内容，保留前面的旧版声明。`--check` 不写文件，清单过期时返回非零。许可证全文以各链接、缓存中的许可文件及 Flutter 产物 NOTICES 为准；此清单不等于法律适用性判断。
