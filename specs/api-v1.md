# `/api/v1` 接口契约

版本：v1。金额与 token 的表示规则全篇统一，任何视图不得自行定义第二套。

---

## 一、通用规则

| 项 | 规则 |
|---|---|
| 基址 | `http://127.0.0.1:<port>/api/v1`，只监听回环 |
| 鉴权 | `Authorization: Bearer <token>`；token 由启动时生成并写入 `<dataDir>/api-token` |
| `Host` | 必须是 `127.0.0.1:<port>` 或 `localhost:<port>`，否则 421 |
| `Origin` | 写请求必须同源或缺省，否则 403 |
| CORS | 不下发任何 `Access-Control-Allow-*` |
| token 数 | JSON 整数。未知 = `null`，**不是 0** |
| 金额 | 十进制字符串，6 位小数，单位 USD。未知 = `null` |
| 时间 | 请求用 `YYYY-MM-DD`（按 `tz` 解释）；响应用 UTC ISO8601 |
| 时区 | 参数 `tz`，默认进程本地时区；同一响应内只用一种 |
| 快照 | 每个响应带 `snapshot: { generated_at, price_version, tz, filters }`；`generated_at` 表示数据快照的生成时刻，usage 缓存命中时保留首次成功计算的值，不表示本次响应的发送时刻 |
| 分页 | 游标式，`next_cursor` 为不透明字符串 |

错误体统一：

```json
{ "error": { "code": "invalid_range", "field": "from", "message": "from 晚于 to" } }
```

| 状态 | code | 场景 |
|---|---|---|
| 400 | `invalid_param` | 参数类型或取值不合法 |
| 401 | `unauthorized` | 缺 token 或 token 不符 |
| 403 | `forbidden_origin` | 写请求来源不符 |
| 404 | `not_found` | 未知路由或资源 |
| 409 | `sync_in_progress` | 已有同步在跑 |
| 421 | `bad_host` | Host 不在白名单 |
| 500 | `internal` | 未预期错误，不泄露堆栈 |

## 二、端点

### `GET /health`

```json
{ "ok": true, "version": "1.0.0", "port": 3456, "data_dir": "...", "db": { "path": "...", "schema_version": 4 } }
```

不需要鉴权（仅返回存活信息，不含数据）。

### `GET /usage/summary`

| 参数 | 说明 |
|---|---|
| `from`, `to` | 可选，闭区间 |
| `tz` | 可选 |
| `source`, `model` | 可选，多值用重复参数 |

```json
{
  "totals": {
    "gross_tokens": 4120000,
    "input_tokens": 1100000,
    "output_tokens": 520000,
    "cache_read_tokens": 2000000,
    "cache_write_tokens": 500000,
    "cost_usd": "65.325000",
    "unpriced_records": 0,
    "record_count": 2
  },
  "rolling": { "last_7d": { "gross_tokens": 4120000 }, "last_30d": { "gross_tokens": 4120000 } },
  "activity": {
    "sessions": 12,
    "turns": 340,
    "cache_hit_ratio": 0.6452,
    "first_seen": "2026-09-25T01:00:00.000Z",
    "last_seen": "2026-10-18T03:00:00.000Z",
    "active_span_ms": 1994400000
  },
  "snapshot": { "generated_at": "...", "price_version": "…", "tz": "Asia/Singapore", "filters": {} }
}
```

约束：`gross_tokens` 必须等于四个分项之和。视图不得返回 `billable_total_tokens` 这类含义重叠的第二个总量。

`activity` 的口径：`sessions` 是去重后的 session_id 数；`turns` 是 `kind='event'` 的记录条数（累计型不计入，它是一份快照不是一轮）；`cache_hit_ratio` = 缓存读 /（输入 + 缓存读），分母为 0 时给 `null`；`active_span_ms` 是首末观测时间之差，只有一个时间点时给 `null`。

### `GET /usage/timeseries?granularity=day`

`day` / `month` / `hour`。返回 `points[]`，每项：

```json
{ "bucket": "2026-10-10", "gross_tokens": 4000000, "input_tokens": 1000000, "output_tokens": 500000,
  "cache_read_tokens": 2000000, "cache_write_tokens": 500000, "cost_usd": "64.875000" }
```

累计快照（`kind='cumulative'`）的开始时间 `observed_at` 与最后活动时间 `ended_at` 落在同一个桶（同一粒度、同一时区）时，计入该桶；跨桶的、或 `ended_at` 未知的，不出现在 `points`，只出现在 `unallocated`。所以同一批数据按小时看会比按天看多出一些 `unallocated`：


```json
{ "unallocated": { "gross_tokens": 12000, "reason": "cumulative_without_time_distribution" } }
```

### `GET /usage/matrix?granularity=day&by=model`

时间 × 维度的明细矩阵。`granularity` 取 `hour`/`day`/`month`，`by` 取 `model`/`source`/`project`。

```json
{
  "granularity": "day",
  "by": "model",
  "rows": [{ "bucket": "2026-10-18", "key": "claude-opus-5-5", "gross_tokens": 2400000, "cost_usd": "8.30" }],
  "unallocated": { "gross_tokens": 120000000, "record_count": 12, "reason": "cumulative_without_time_distribution" },
  "snapshot": { "…": "…" }
}
```

约束：`sum(rows) + unallocated == totals`。累计快照的归桶规则与 timeseries 相同：同一个桶内结束的进矩阵，其余只能出现在 `unallocated`。

### `GET /usage/breakdown?by=model|source|project|source_model`

每组一项，字段与 summary 的 `totals` 同构，另加 `key`、`price_state`、`cost_by_kind`。**组内数值不得被上级总量重复相加**；同一响应里 `sum(groups) == totals`。

`cost_by_kind` 把该组金额按 token 类型拆开：

```json
"cost_by_kind": { "input": "0.080000", "output": "170.000000", "cache_read": "480.000000", "cache_write": "150.000000" }
```

分项由定价引擎按每条已定价记录计算，再用整数 micro-USD 累加；缓存写的五分钟与一小时档分别取整后合并到 `cache_write`。API 不从聚合 token 重算，不把差额分配给其他分项。分项非 `null` 时，四类之和严格等于该组 `cost_usd`。

全组未定价时分项为 `null`；部分记录未定价时只累计已定价部分，保留 `unpriced_records`。有价格且金额为零时返回四个 `"0.000000"`。任一已定价记录的 `price_version` 缺失、与当前目录不一致，或引擎计算与已存金额不符时，整个组的分项为 `null`，该组 `cost_usd` 仍取账本，不改写历史记录。聚合与分项读取期间数据变化导致两者总额不一致时也返回 `null`。

`by=source_model` 按「工具 × 模型」两维分组：每组额外带 `source` 与 `model`，`key` 等于 `model`（同一个模型在不同工具下各成一组，身份是 `source` + `model` 一对）。`price_state` 按该组模型标注。首页用它一次拿全工具排行、每个工具的模型数与常用模型。

### `GET /sessions`

| 参数 | 说明 |
|---|---|
| `limit` | 默认 50，上限 200 |
| `cursor` | 上一页 `next_cursor` |
| `source`, `from`, `to` | 可选筛选 |

```json
{ "items": [ { "session_id": "...", "source": "codex", "project_key": null,
  "started_at": "...", "last_seen_at": "...", "gross_tokens": 3000000,
  "cost_usd": "12.345000" } ],
  "next_cursor": null }
```

### `GET /sessions/detail?source=&session_id=`

单个会话的明细。`source` 与 `session_id` 必须同时给 —— 不同来源可能撞同一个 session id。

```json
{
  "session": {
    "source": "claude", "session_id": "9083b3a7-…", "project_key": "D:\\work\\app",
    "started_at": "2026-10-19T03:36:49.471Z", "last_seen_at": "2026-10-19T06:22:16.562Z",
    "gross_tokens": 1300000, "input_tokens": 120000, "output_tokens": 80000,
    "cache_read_tokens": 1000000, "cache_write_tokens": 100000,
    "cost_usd": "0.123456", "unpriced_records": 0, "record_count": 96
  },
  "models": [
    { "model": "claude-opus-5-5", "price_state": "verified",
      "gross_tokens": 1300000, "input_tokens": 120000, "output_tokens": 80000,
      "cache_read_tokens": 1000000, "cache_write_tokens": 100000,
      "cost_usd": "0.123456", "unpriced_records": 0, "record_count": 96 }
  ],
  "timeline": [
    { "bucket": "2026-10-19T10:00:00", "gross_tokens": 24000, "cost_usd": "0.002100",
      "input_tokens": 2000, "output_tokens": 1000, "cache_read_tokens": 20000,
      "cache_write_tokens": 1000, "unpriced_records": 0, "record_count": 4 }
  ],
  "kinds": { "event": 96, "cumulative": 0 },
  "granularity": "hour",
  "snapshot": { "…": "…" }
}
```

- `timeline` 只统计事件型记录。累计型是会话快照，没有连续分布，条数由 `kinds.cumulative` 给出。
- 会话跨多个项目时 `project_key` 为 `null`，不替调用方挑一个。
- `granularity` 只接受 `hour`（默认）与 `day`。
- 缺 `source` 或 `session_id` → 400 `invalid_param`；会话不存在 → 404 `not_found`。

### `GET /sources`

```json
{
  "sources": [
    { "source": "codex", "evidence": "A", "status": "ok",
      "first_observed_at": "...", "last_observed_at": "...",
      "records": 25, "record_mode": "event",
      "retention": { "reviewable": 20, "logs_gone": 5 },
      "checks": { "time_out_of_range": 0, "huge_requests": 0, "null_model": 0, "mixed_kind_sessions": 0 },
      "limits": ["cached ⊂ input，已在适配层扣减"],
      "notes": [{ "text": "Codex 报的输入里包含缓存的部分，这里已经拆开，不会重复算。", "impact": "handled" }] }
  ],
  "last_run": {
    "status": "completed_with_anomalies",
    "started_at": "2026-10-18T11:15:20.000Z",
    "finished_at": "2026-10-18T11:15:24.000Z",
    "attempted": 158, "inserted": 138, "updated": 0, "unchanged": 20, "rejected": 0,
    "counts": { "read_failed": 1, "cross_file_copies": 0, "relabeled": 0, "reactivated": 0, "replaced": 0, "deactivated": 0,
                "vanished": 0, "rev_corrections": 0, "cumulative_decrease": 0 },
    "anomaly_count": 1,
    "anomalies": ["read_failed: claude /x — boom"]
  }
}
```

`status` 取值：`ok` / `no_data`。`evidence` 是证据等级：`A` 表示逐字段对照过真实样本，`B` 表示只有合成样本。

`first_observed_at` 是这个来源最早一条记录的时间，界面用它给工具分配固定的图表颜色：先出现的工具先占色，以后不再变。`record_mode` 从账本里实际存的记录类型得出：`event` 每次请求一条，`cumulative` 每个会话只有一条总数，`mixed` 两种都有。

`retention` 按出处日志是否还在磁盘上分两类：`reviewable` 是 `source_file` 仍存在、可以对照原始日志复核的条数；`logs_gone` 是日志已删或没有出处（schema v4 之前写入、此后再没被重读）的条数，照常计入总数。两者之和等于 `records`。

`checks` 是账本自检，数的都是活跃记录：`time_out_of_range` 开始或结束时间晚于请求时刻，或开始早于 2023-01-01；`huge_requests` 逐条请求（`kind = event`）的 gross 超过 1 亿，累计快照是整场会话的总数，不在此列；`null_model` 没有模型名、不计价；`mixed_kind_sessions` 同一会话里既有逐条请求又有累计快照的会话数，混用会重复计数。全为 0 表示没发现异常。

`limits` 是口径原文，`notes` 与它一一对应，是给使用者看的说明。`impact` 为 `affects` 表示数字会因此有偏差或缺一块，`handled` 表示已经处理、不影响总量。

`last_run` 是最近一次采集运行，从未采集过时为 `null`。`anomalies` 最多带 5 条，`anomaly_count` 是完整条数。

`last_run.status` 取值：`running`（采集开始时就登记，进行中可见）、`ok`、`completed_with_anomalies`、`failed`（运行中途抛错）、`abandoned`（上一次运行没走到收尾，下一次运行时补标）。`counts` 是按类计数（schema v4 起，更早的运行为 `null`）：`read_failed` 读取或解析失败、整份未入库的文件数；`bad_lines` 无法解析的日志行或行内、附属 JSON 数据；`bad_fields` 存在但不是非负整数的 token 字段；`bad_times` 时间缺失或非法、整条未入库的记录；`zero_usage` 四类 token 均为 0 或未知、未入账的记录；`cross_file_copies` 同一条事件记录在同一来源的另一个文件里又出现、只计一次而跳过的副本数；`relabeled` 只补项目归属；`reactivated` 恢复计入；`replaced` 被新身份接替的旧行；`deactivated` 因解析器版本变化而停用；`vanished` 同版本下不再出现、照常计入；`rev_corrections` 因版本变化而接受的累计值下降；`cumulative_decrease` 被拒绝的累计值下降。这条路径存在的意义是让采集失败可见——否则用户看到的只是「数字没变」。

### `POST /sync`

无请求体。返回：

```json
{ "run_id": 12, "status": "ok", "attempted": 120, "inserted": 3, "updated": 1,
  "rejected": 0, "duration_ms": 812 }
```

并发时返回 409 `sync_in_progress`。同一时刻只允许一个同步（进程内串行 + 跨进程文件锁）。

### `GET /pricing`

```json
{
  "price_version": "2bb8b6a65aaf1fb6",
  "verified_at": "2026-10-19",
  "currency": "USD",
  "provisional": true,
  "models": [
    {
      "model": "claude-opus-5-5",
      "records": 17876,
      "state": "verified",
      "billing": "metered",
      "local_records": 0,
      "local_providers": {},
      "source_url": "https://…",
      "note": "标准按需；缓存写分 5 分钟档（5.00）与 1 小时档（8.00），按实际上报档位计价",
      "prices": {
        "input": 4, "output": 20, "cache_read": 0.2,
        "cache_write_5m": 5, "cache_write_1h": 8
      },
      "tiers": null,
      "time_of_day": null,
      "price_marks": { "": 17876 }
    }
  ],
  "counts": { "verified": 14, "aggregate": 3, "unknown": 1, "local": 0 },
  "snapshot": { "…": "…" }
}
```

- `prices` 的单位是 **USD / 百万 token**，按目录原值输出、不做舍入；某个分项不单独计价时为 `null`，不是 0。模型未定价时整个 `prices` 为 `null`。
- `state` 取值：`verified`（厂商官方页核验）/ `aggregate`（聚合库或市场价）/ `unknown`（查不到）/ `local`（该模型的全部活跃记录都明确来自本地提供方）。`counts` 增加 `local` 模型数；纯本地模型不计入 `unknown`。
- `billing` 与价格可信度是两件事：`plan` 表示厂商按套餐售卖，金额是这些 token 的公开市场价折算，不是账单。
- `billing` 增加 `local`：纯本地模型的金额和 `prices` 五项均为 0，`tiers`、`time_of_day`、`source_url` 为 null。`price_source` 写为 `local:<小写提供方 ID>`，但不会给未知历史行猜 provider。
- 每个模型增加 `local_records`（本地提供方记录数）和 `local_providers`（小写提供方 ID 到记录数的对象，如 `{ "ollama": 3 }`；没有本地记录时为 `0` 与 `{}`）。同名模型混用本地和远端时保留目录的 `state`、`billing`、`prices` 与条件价格，另显示本地条数，避免把远端记录也当成本地；模型名为 null 也遵循同一分组规则。
- `tiers` 为 `null` 或 `[{ above, prices }]`。`above` 的单位是 token；单次请求的提示长度（新输入 + 缓存读 + 缓存写）严格超过阈值时，整条请求按对应档位计价。多档按阈值递增排列；累计快照用基础档。每档 `prices` 与基础 `prices` 的五项、单位和 `null` 语义相同。
- `time_of_day` 为 `null` 或 `{ utc_offset_minutes, peak, off_peak_prices, holidays_count, holidays_through }`。基础 `prices` 是高峰价，`off_peak_prices` 是低谷价，形状和单位相同。`utc_offset_minutes` 是相对 UTC 的分钟偏移；`peak` 为 `[{ days, from, to }]`，`days` 是当地星期（0 周日至 6 周六），`from`、`to` 是当地午夜起的分钟数，区间左闭右开 `[from, to)`。其余时段和已登记节假日全天按低谷价。
- `holidays_count` 是节假日表的日期数，`holidays_through` 是其中最晚的 `YYYY-MM-DD` 日期；空表时为 `0` 和 `null`。截止日期只表示最后登记日，不表示此前所有日期都是节假日，也不保证覆盖到当年年底。未登记年份的节假日仍按星期和时段判断；周末补班日按周末计。
- `price_marks` 是该模型全部活跃记录的计价标记计数，不受日期筛选影响。键取账本 `price_source` 第一个 `;` 后的完整后缀，不含来源前缀；没有分号、后缀为空或 `price_source` 为 `null` 时键为 `""`。多个标记保留为同一个后缀键，不重复计数；各键之和等于 `records`。未定价、缺模型的记录也计入。
- 常见标记：`tier:<阈值>`（高档）、`tier:cumulative`（累计快照用基础档）、`tier:unknown`（提示长度不完整，用基础档）、`tod:peak`、`tod:offpeak`、`tod:blend`（按累计区间的峰谷时长加权）、`tod:weekly`（区间未知，用一周固定占比）。空键只表示没有标记，不能据此断言已知为基础档。这些标记反映账本记录写入时所用的规则，目录字段反映当前内置价表。

有条件变价的字段例子（计数为示例）：

```json
{
  "model": "gpt-6.1-sol",
  "tiers": [{ "above": 272000, "prices": {
    "input": 4, "output": 15, "cache_read": 0.2,
    "cache_write_5m": 5, "cache_write_1h": null
  } }],
  "time_of_day": null,
  "price_marks": { "tier:272000": 1000, "tier:unknown": 13000, "": 40 }
}
```

```json
{
  "model": "deepseek-flash",
  "tiers": null,
  "time_of_day": {
    "utc_offset_minutes": 480,
    "peak": [
      { "days": [1, 2, 3, 4, 5], "from": 540, "to": 720 },
      { "days": [1, 2, 3, 4, 5], "from": 840, "to": 1080 }
    ],
    "off_peak_prices": {
      "input": 0.15, "output": 0.6, "cache_read": 0.003,
      "cache_write_5m": null, "cache_write_1h": null
    },
    "holidays_count": 33,
    "holidays_through": "2026-10-07"
  },
  "price_marks": { "tod:offpeak": 36, "tod:blend": 100, "tod:weekly": 37 }
}
```

`tiers`、`time_of_day`、`price_marks`、`local_records`、`local_providers` 均为只增字段；`state` 与 `billing` 只增加 `local` 取值，其他取值的含义不变。旧页面仍可读取基础 `prices`，新版页面能表达本地状态。接口只查询本地账本与内置目录，不重算、不写入、不触发联网；沿用 `/api/v1` 的 loopback 与 bearer 校验。整个列表用一次按模型、provider 和标记聚合的查询，同时返回模型记录数、本地条数与标记计数，避免并发采集造成两次读取的快照不一致；不逐模型查账本。前后端随本地软件一起升级；schema v5 账本会被只支持 v4 的旧程序拒绝，不能直接回退旧程序写库，需恢复升级前备份。

### `POST /pricing/refresh`

只接受用户点击触发。禁止在任何页面加载、后台同步、定时任务里调用。失败返回来源错误，不静默回退到旧值。

## 三、已删除的旧入口

`/functions/token-lens-*` 与 `/api/local-auth` 已随旧前端一起删除。`/api/` 与 `/functions/` 前缀下不存在的路径一律返回 404 JSON，不回落成 SPA 页面——调用方不该把一页 HTML 当成数据。

## 四、不变量

1. 任一响应内 `gross == input + output + cache_read + cache_write`。
2. 同一 `snapshot` 下，breakdown 的分组之和等于 summary 的 totals，Token 与金额都是。
3. 未知值只以 `null` 出现，任何层都不得把未知折成 0。
4. 金额只以字符串出现，不经浮点。

## 五、`GET /api/v1/discovery`

引导页在同步之前先做一次检测：这台电脑上每个工具找到了几个日志文件。

```json
{
  "sources": [
    { "source": "claude", "files": 2 },
    { "source": "codex", "files": 1 }
  ],
  "supported": 22
}
```

- `sources` 只列 `files > 0` 的工具，按 `files` 降序；`files` 是该工具发现的日志文件数。
- `supported` 是适配器注册表（`src/core/adapters/index.js`）里的工具总数，与检测结果无关。
- **不返回任何文件路径**：数量足够引导页显示「N 个日志文件」，路径是用户隐私，也与统计无关。
- 不带 `snapshot`：这是同步前的检测状态，不涉及账本数据。鉴权、Host、Origin 规则与通用规则一致。
- 扫盘结果在服务端缓存 60 秒。`?fresh=1` 跳过缓存重扫，给引导页的「重新检测」用。
