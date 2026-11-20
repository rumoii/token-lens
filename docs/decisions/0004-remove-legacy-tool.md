# 0004 开源前从仓库删除旧版 Node/React 工具

日期：2026-11-20　状态：有效

## 背景

桌面版完成数据副本验收（D4）后，旧版 Node/React 工具冻结，只留作回退。它在仓库里有自己的一套代码、测试、CI 和 Node 依赖，新贡献者不容易分清哪部分是现行代码。

## 决定

- 在 v0.1.0 之前删除 `src/`、`dashboard/`、`desktop/`、`bin/`、旧版测试和脚本。删除前的最后一个提交打标签 `legacy-node`，旧版从那里取回。
- 旧版生成的对拍夹具和金标准移到 `app/rust/tests/`，冻结，不再重新生成。
- 只描述旧版的文档移到 [docs/archive/](../archive/)。

## 后果

- 桌面版不再能和旧版做新的对拍；Rust 行为需要与旧版不同时，在测试里显式处理，写进 [stats.md](../development/stats.md)「允许的差异」。
- 旧版账本 `~/.token-lens` 仍可手动复制给桌面版接手，做法见 [app/README.md](../../app/README.md)。
