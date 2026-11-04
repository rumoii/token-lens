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
