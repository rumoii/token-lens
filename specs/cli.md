# Token Lens CLI 与明细导出（格式 v1）

桌面发行包包含 Windows 的 `token-lens-cli.exe`（与 `token-lens.exe` 同目录）和 macOS 的 `Token Lens.app/Contents/MacOS/token-lens-cli`。它们与应用使用同一个账本和价格目录。

```text
token-lens-cli [--data-dir ABSOLUTE] [--project-paths] [--pretty] COMMAND
```

数据目录依次取 `--data-dir`、`TOKEN_LENS_PREVIEW_DATA_DIR`、平台默认目录。前两个值须为绝对路径。Windows 默认目录为 `%APPDATA%\Token Lens\Token Lens\data`，macOS 为 `~/Library/Application Support/io.github.rumoii.token-lens/data`。调试构建必须显式提供数据目录。同步从 `TOKEN_LENS_PREVIEW_HOME` 或系统用户主目录发现日志。调试同步要求设置 `TOKEN_LENS_PREVIEW_HOME`。开启预览日志根时沿用应用的隔离发现规则。

## 命令

| 命令 | `data` |
| --- | --- |
| `status` | `ledger_version`、`price_version`、`tools_with_usage`、`last_sync` |
| `summary` | 用量字段。加 `--compare` 时为 `current`、`previous`（含 `query` 和 `totals`）、`delta` |
| `breakdown --by tool\|model\|project\|day\|hour\|month` | `by` 和 `rows`。每行有 `key` 和用量字段 |
| `sessions [--sort recent\|cost\|tokens] [--limit N] [--cursor CURSOR]` | `items` 和可空的 `next_cursor`。每项有用量字段、`tool`、`session_id`、`started_at`、`last_seen_at`、`project` |
| `session --tool SOURCE --id SESSION` | 整个会话的时间范围、来源、会话 ID、项目和用量字段，另有 `models` 数组，其每项含 `model` 和用量字段。找不到会话时记录数为 0，时间范围为空 |
| `sources` | `sources` 数组。每项含 `tool`、`name`、`record_count`、`first_observed_at`、`last_observed_at`、`last_sync_status` |
| `sync` | `attempted`、`inserted`、`updated`、`unchanged`、`rejected`、`repriced`、`file_count`、`parsed_files`、`cached_files`、`skipped_files`、`duration_ms` |
| `--help`、`--version` | `usage`、`version`。不需要账本 |

`last_sync` 含 `started_at`、`finished_at`、`status`、`trigger`、`age_seconds` 及 `counts`。账本没有同步历史时为 `null`。旧同步历史的触发方式和每工具同步结果可以是 `null`。未处理某工具的同步不覆盖该工具已有的结果。

`summary`、`breakdown` 和 `sessions` 接受 `--period today|week|month|all`，默认 `month`。也可传入 `--from YYYY-MM-DD --to YYYY-MM-DD`，首尾日期均包含。按系统时区处理，周从周一开始，周和月截至当天。三条命令都支持 `--tool`、`--model`、`--project`。项目筛选接受完整匹配路径、项目名称或消歧后的显示名称。存在完全匹配的路径时优先采用该路径。

比较在同一个 SQLite 读事务内取本期、上期和本期减上期的结果。当天比较昨天，本周比较上周相同星期范围，本月比较上月 1 日至同日（上月较短则截至月末），自定义范围比较紧挨起点的等长日期区间。`all` 没有上期。

会话列表默认按最近活动排序，默认每页 20 条，接受 1 到 200。金额顺序中没有任何已计价记录的会话排最后。相同排序值按会话 ID、来源 ID 排序。用相同筛选与排序传回原样的 `next_cursor`，直到它为 `null`。游标基于上一页末条的排序位置。账本发生同步后，重新从第一页开始可得到更新后的完整列表。

## JSON 契约

成功退出码为 0。stdout 恰好一个 UTF-8 JSON 对象，可用 `--pretty` 缩进。

```json
{
  "format_version": 1,
  "command": "summary",
  "generated_at": "2026-11-19T14:00:00.000Z",
  "freshness": {
    "last_sync_at": null,
    "last_sync_status": null,
    "age_seconds": null
  },
  "query": {
    "period": "today",
    "from": "2026-11-19",
    "to": "2026-11-19",
    "timezone": "America/New_York",
    "filters": {"tool": null, "model": null, "project": null}
  },
  "data": {
    "input_tokens": 100,
    "output_tokens": 10,
    "cache_read_tokens": null,
    "cache_write_tokens": null,
    "total_tokens": 110,
    "record_count": 1,
    "request_count": 1,
    "session_count": 1,
    "cost_usd": "0.000650",
    "cost_micros": 650,
    "currency": "USD",
    "unpriced_records": 0
  }
}
```

四类 token 字段在选中记录的该类用量全部未知时返回 `null`，有已知用量时合计已知值。空范围的用量为零。请求数只计请求级记录。金额只统计已计价记录，用美元字符串和整数微美元同时表示，未计价记录单独计数。`session_count` 在各自范围内按 `(source, session_id)` 去重。**会话数不可跨组相加**。同一会话可以在多个组出现。跨时间桶的累计记录和无法分配到具体时间桶的记录进入 `key: null` 组，因此记录数、token 和金额与汇总一致。

项目名称按 Windows 或 Unix 分隔符取末级。同一结果集内有同名项目时，使用 `上一级 / 项目名`。无项目时名称为 `null`。只有 `--project-paths` 或导出菜单中的相应选项打开时，相关字段才可包含 `project_path`。记录键、源文件、内容哈希、日志路径和数据目录路径不属于输出契约。

失败时 stdout 为空，stderr 恰好一个 JSON 对象。

```json
{"format_version":1,"error":{"code":"no_ledger","message":"No ledger exists. Open Token Lens or run sync first."}}
```

| 退出码 | `error.code` | 含义 |
| --- | --- | --- |
| 1 | `usage` | 参数无效 |
| 2 | `no_ledger`、`ledger_version` | 账本缺失或账本版本不受支持 |
| 3 | `sync_busy` | 同步锁已被占用 |
| 4 | `failed` | 其余执行失败 |

只读命令用 SQLite 只读连接读取版本 7 的账本，支持打开应用写入的 WAL。它们不触发同步或迁移，也不写运行日志。`sync` 走应用的同步入口、跨进程锁、升级备份和运行日志，触发方式为 `cli`。

同一 `format_version` 只增加字段。改名、删字段或改语义时增加版本号。客户端应容忍未知字段。

## 明细页文件

明细卡片能按当前筛选和工具、模型、项目、小时、天或月分组导出。请求分组没有导出入口。默认存入系统下载目录，无法取得下载目录时使用应用数据目录的 `exports`。文件名是 `token-lens-<分组>-<起>-<止>.<csv|json>`，无日期边界时对应位置写 `all`。重名依次加 `-2`、`-3`。

JSON 与同一时点、同一筛选下的紧凑 CLI `breakdown` 字节一致。CSV 的列对应 `data.rows` 字段，使用 UTF-8 BOM 和表头，空值为空单元格。以 `=`、`+`、`-`、`@`、制表符或回车开头的单元格加单引号前缀。
