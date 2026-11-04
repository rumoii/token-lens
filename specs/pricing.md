# 定价与金额契约

## 零、这个金额是什么

**金额是「这些 token 在公开市场上值多少」的估算，不是用户的账单。**

这个区分决定了套餐制怎么处理：厂商按订阅售卖时，用户没有按 token 付钱，但 token 依然有价值。把这些用量记成「无价格」会让看板少掉一整块，记成 0 会显示成免费——都对用户没用。所以套餐制模型照样按公开市场价折算，另用 `billing: 'plan'` 标明计费方式。

价格来源分两档，都写进 `price_source`：

| 档 | 含义 | 标记 |
|---|---|---|
| 官方核验 | 厂商官方价目页逐条对照，带 URL 与核验日期 | `verified:<model-id>` |
| 聚合/市场价 | models.dev 等公开聚合或转售报价，未在厂商页核验 | `aggregate:<model-id>` |

本地提供方按第九节第 5 条计 0；其余查不到任何公开价的模型是「未定价」，返回 `cost_micros = null`。

---

## 一、价的来源

优先采用厂商公开的商业标准价（公网 API 标价）。厂商没有公开按量价时，按第九节第 1 条取网关公开标价，标 `aggregate`。不采用反代、内部渠道或批量折扣价。

每个价格条目必须带：

```js
{
  id: 'claude-opus-4-1',
  aliases: ['claude-opus-4-1-20250805'],
  currency: 'USD',
  perMTok: { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 }, // 单位：USD / 1M tokens
  sourceUrl: 'https://…',
  verifiedAt: '2026-10-17',
  conditions: '标准按需计费；不含批处理折扣'
}
```

- 匹配按**精确模型 ID**，再查显式别名表。不按模型家族正则匹配——同族不同版本价差过大，按家族套价无法支撑「官方标价」的说法。
- 查不到任何公开价 = 未定价。未定价不是 0。
- 每个条目的 `verifiedAt` 是核验日期，不等于价格生效日期；两者不一致时以 `conditions` 说明。

## 二、价与用量分离

| 存储 | 内容 |
|---|---|
| `usage_records` | 用量事实（四类 token、时间、来源、模型） |
| `pricing_snapshot` | 某一时点的价表快照，`version` = 目录内容哈希 |

换价格版本只重算 `cost_micros`，不改用量事实。历史可按任意保留的价格版本重新估值。

## 三、金额计算

内部一律整数，单位 **micro-USD**（USD × 1e6）：

```
part_micros = floor(tokens * perMTok_micros / 1_000_000)
```

其中 `perMTok_micros = round(perMTok * 1e6)`。每条记录的各分项使用 BigInt 整数除法向下取整后相加，不在合并 token 后重新取整；缓存写有五分钟与一小时分档时，两档分别计算后合并：

```
total_micros = input_cost + output_cost + cache_read_cost + cache_write_cost
```

`pricing/engine.js` 的 `priceRecord` 是总额与分项的唯一计算入口，返回整数分项及价格元数据；`costOf` 使用同一结果，保持原来的三个返回字段和金额口径。禁止在聚合路径用浮点费率重新计算金额或使用 SQL `REAL`。

`LedgerQueries.costRows` 以 SQLite iterator 流式读取已定价记录，共用聚合查询的 active、日期、时区和维度过滤。API 逐行核对价格版本及已存金额，核对失败只把所在组的分项标为 NULL，不改变账本和其他组。

## 四、展示舍入

API 的 `cost_by_kind` 固定六位小数，直接由已核对的整数 micro-USD 转换，不分配差额。价格版本缺失、过期、金额不匹配或读取期间变化时，分项为 NULL，已存总额照常返回。

较低显示精度可使用现有 `allocateDisplay` 的**最大余数法**；该函数不参与六位小数 API 分项计算：

1. 每个分项按目标小数位向下取整，记录余数。
2. 把剩余的最小单位按余数从大到小逐项补齐（余数相同按传入顺序稳定排序）。
3. 保证 `sum(displayed_parts) == displayed_total`，且不等于的情况视为缺陷。

目标显示总额直接从 `total_micros` 截取到目标精度，不从分项重新估算。

## 五、未知与部分已知

| 情形 | 表现 |
|---|---|
| 模型无价 | `cost_usd = null`，`unpriced_records` 计数 +1，界面显示「未定价」 |
| 目录分项费率为 NULL | 表示该分项不单独计价，金额按 0 计入；保持现有价表口径 |
| token 未知（NULL） | 该分项不参与任何求和；聚合层区分「未知」与「零」 |
| 已存价格版本缺失或过期 | 保留已存总额，查询分项为 NULL，不套当前费率推断历史分项 |
| 部分记录未定价 | 只累计已定价部分，并保留 unpriced_records；全组未定价时分项为 NULL |
| 已定价且总额为 0 | 分项为四个 0，与未定价的 NULL 区分 |

## 六、缓存读写的位置

不同客户端对「缓存写」的计费方式不同：有的按写入 token 单独计价，有的把写入并入输入价。`perMTok.cacheWrite = null` 表示**该模型不单独计价**，对应 token 数照常统计，金额按 0 计入但不显示为「未知」。

这条规则必须写在每个价格条目里，而不是在计算函数里按模型名判断。

## 七、不变量

1. 分项可核对时，`sum(各分项金额) == 已存总额金额`；不可核对时分项为 NULL，不编造分摊。
2. 未定价不计入总额，但必须计数并可在界面查到是哪几个模型。
3. 同一 `price_version` 下同一数据集重复计算，结果逐字节相同。
4. 只累加整数 micro-USD，不用浮点费率在 API 重算金额。

## 八、R3 验收证据

范围：复用阶段 R3 的已批准规格，不改 schema、价表及价格版本，不重算历史数据。金额分项错误可能误导费用归属，因此按金额计算的高保障流程验证。

| 行为与失败模式 | 检查 |
|---|---|
| 一小时缓存写差价归错项、混合分档错误、合并后取整产生偏差 | `test/core/cost-parts.test.js` 的四种分组、分档与逐条取整场景；`cache-split.test.js` 的既有定价测试 |
| 未定价与零价混淆、部分未定价、NULL 与空项目碰撞 | cost-parts 的零价、部分已知、项目分组场景；matrix 的跨模型分项合计测试 |
| 旧价格、已存金额偏差、正负偏差抵消、读取期间数据变化 | cost-parts 的版本、逐行核对、组间隔离与读取交错场景；不匹配返回 NULL，总额保留 |
| 误写历史数据、遗漏筛选或 inactive、HTTP 组装改变结果 | cost-parts 的完整行只读对比、时区筛选和真实鉴权 HTTP 请求；router-contract 的既有接口测试 |
| 引擎重构改变已存金额口径 | 与 R2 提交的 costOf 对比 416 组输入，覆盖 26 个模型/别名/未知值组合；金额及价格元数据均一致 |

新增 API 场景首次在旧实现运行，17 项中 16 项失败，复现缓存差价与逐条取整偏差、旧价强行分摊等问题；修复后核心测试共 220 项通过。真实 HTTP 测试使用显式临时数据目录；只读性测试仅对自建临时库写入夹具，验证查询前后行内容和 schema v3 不变。

合成性能验证：内存账本 100,000 行、20 个项目的 breakdown 单次约 387ms，分项合计与各组金额相等；该结果不代表实际账本或其他机器的耗时。前端目前只声明分项类型，未消费该字段；本阶段验收覆盖核心与 HTTP，不声称完成实际账本或浏览器现场验证。


## 九、阶段 P 契约（2026-10-26 定；第 2、3、4、5 条已实现）

本节是 [roadmap.md](roadmap.md) 阶段 P 的规则。`provider` 是 schema v5 的可空输入；非本地提供方仍按第三节计算。

### 1. 来源分级

- 厂商官网有按量标价：用官网价，`tier` 为 `verified`。
- 厂商没有公开按量价（只按套餐卖，或只在网关上卖）：取 OpenCode Zen、OpenRouter 等网关的公开标价，`tier` 为 `aggregate`，`conditions` 写明是哪个网关、哪天取的。
- 只有厂商官方页的历史快照、当日无法核验时也标 `aggregate`；`conditions` 须写明快照来源与快照日期，查不到具体日期就写「日期未知」。此时 `verifiedAt` 表示快照复核日期，不表示当日官网核验。
- 两者都有时用官网价。网关价可能加价或打折，不和官网价混用。
- 套餐里的模型名（如 `kimi-code/k3.1-pro`）先对应到厂商 API 模型：对应关系写进 `aliases`，依据写进 `conditions`；对不上的保持未定价。

### 2. 计价输入

`priceRecord` 在现有字段外读取 `kind`、`observed_at`、`ended_at` 和 `provider`。写入、`reprice` 和 `costRows` 的逐行核对用同一组字段，否则核对会把正确的已存金额判成不匹配。

### 3. 长上下文分档

- 条目可带 `tiers: [{ above, perMTok }]`。`above` 是单次请求提示 token 数的阈值，超过它时整条请求的各分项都按该档计价；有多档时取满足条件的最高一档。
- 提示长度 = `input + cache_read + cache_write`，只对 `kind = 'event'` 生效。
- 某项为 NULL 时：已知项之和已经超过阈值，照样用高档；否则无法判断，用基础档，`price_source` 加 `;tier:unknown`。
- 累计快照算不出单次提示长度，用基础档，`price_source` 加 `;tier:cumulative`。用了高档时加 `;tier:<above>`。
- 阈值以厂商官网为准；`verifiedAt` 记的是核验阈值的日期。
- 已登记（2026-10-26 核验）：gpt-6.1-sol、gpt-6-sol、gpt-6-astra、gpt-6-luna 为输入超过 272K（官网：Short context ≤272K input tokens）；claude-haiku-5-5 为提示超过 100,000（官网写明含缓存读写、逐条请求计）。其他 Claude 模型全 1M 上下文按标准价，不分档。

### 4. 峰谷分时

- 条目可带 `timeOfDay: { utcOffsetMinutes, peak, offPeak, holidays }`：时刻一律换算到固定的 UTC 偏移（不用机器时区，也不处理夏令时）；`peak` 列出高峰时段（当地星期 0–6，0 为周日；起止分钟 `[from, to)`），`offPeak` 是低谷时的 `perMTok`，基础 `perMTok` 是高峰价；`holidays` 是全天按低谷计的当地日期。
- 逐条请求：按 `observed_at` 落在高峰还是低谷取价，`price_source` 加 `;tod:peak` 或 `;tod:offpeak`。
- 累计快照：按 `[observed_at, ended_at)` 区间内高峰与低谷的毫秒数加权，每个分项 = `floor(tokens × (高峰单价 × 高峰时长 + 低谷单价 × 低谷时长) / (总时长 × 1e6))`，全程 BigInt，标 `;tod:blend`。`ended_at` 为 NULL、不晚于开始时间或无法解析时，用一周内高峰与低谷时长的固定占比（不计节假日），标 `;tod:weekly`。
- 已登记（2026-10-26 核验）：deepseek-flash 按 DeepSeek 中文定价页，北京时间（UTC+8）周一至周五 9:00–12:00、14:00–18:00 为高峰，其余时段、周末与中国法定节假日全天为低谷，低谷半价。页面写「中国法定节假日」，未提调休：节假日取国务院办公厅放假安排里的全部放假日（含调休放假的工作日），周末补班日按页面「周末」字样计为低谷。目前登记 2026 年；未登记年份的节假日按工作日计，新的放假安排发布后补进目录（会换价格版本）。
- 同一条目暂不同时支持 `tiers` 与 `timeOfDay`，目录加载时检查，两个都写就报错。

### 5. 本地模型（已实现）

- 账本 schema v5 只给 `usage_records` 加 `provider TEXT`，不改已有行；值取日志写明的提供方，NULL 表示未知。适配器不按模型名、路径或客户端推测。
- 内容指纹只在 provider 非 NULL 时，将其原值追加到 v4 指纹输入；NULL 不增加字符或分隔符，与 v4 逐字相同。补到 provider 的行重读后 `revision + 1` 一次，再读不变。迁移本身不改用量、金额、指纹或 revision；后续采集与重算会按当前目录更新估值，本地行金额可因此变为 0。
- `src/core/pricing/catalog.js` 的 `LOCAL_PROVIDERS` 为 `ollama`、`lmstudio`，依据是 OpenCode 官方提供方配置示例中的 ID（见 [log-schemas.yaml](log-schemas.yaml) 的 `local_provider_ids`）；这些是提供方 ID，不能覆盖任意自定义别名，也不检查端点实际运行在哪里。比较时大小写不敏感，账本保留日志原值。命中名单优先于模型查价：金额为 0，四个分项都为 0，`price_source` 为 `local:<小写 ID>`，不计入未定价；其他提供方仍按模型照常计价。
- `/pricing` 对全部记录均为本地提供方的模型返回 `state: local`、`billing: local`、五项零单价；同名模型混用本地和远端时保留目录状态与远端单价，通过 `local_records`、`local_providers` 分别说明本地条数与提供方。界面显示「本地」或混合用量的本地条数。
- 原始日志已经删掉的历史行没有 provider，不按模型名猜；模型没有目录价时保持未定价。本阶段不提供补 provider 脚本，真实账本验收需另行确认。

### 6. 价格版本

`PRICE_VERSION` 的内容哈希包含 `id`、`perMTok`、`verifiedAt`、`tier`、`tiers`、`timeOfDay`、`billing` 和 `LOCAL_PROVIDERS` 本地提供方名单。仅名单变化也会换价格版本，采集后的 `reprice` 使用保存的 provider 重算估值，不改用量事实。

### 7. 不变量

第七节的四条照旧。另加一条：同一条记录的分档或时段判断，只取决于该条记录的字段和价格版本，不取决于计算时刻或机器时区。

### P1 实施记录

2026-11-01 补录 MiniMax-M2.7 与 MiniMax-M2.7-highspeed：依据[官网 API Pricing 的旧搜索快照](https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise)，USD / 1M token 输入、输出、缓存读、缓存写分别为 `0.3 / 1.2 / 0.06 / 0.375` 与 `0.6 / 2.4 / 0.06 / 0.375`。依第九节按未完成当日官网核验处理，标 `aggregate`，不冒称当日官方核验；verifiedAt 记录旧搜索快照的复核日期，原 URL 当前跳转到不再列出 M2.7 的价目总览，实时价格未确认；M2.7 官网标为退役。快照没有缓存写时长分档、长上下文分档或峰谷价，不推定独立 1 小时缓存写价格。MiniMax Code 上游 `MiniMax-AI/minimax-code@da22f11c55d4748155d7162c1030414228a00565` 的 `packages/config/src/minimax-model-catalog.ts` 使用这两个完整 ID，大小写、provider 前缀和版本点号由既有归一化匹配，不增添未经核验的型号别名。独立型号 MiniMax-M3.1 未查到官方 USD 标价，维持未定价，不借用 MiniMax-M3.1-Flash 的价格。[官方模型列表](https://platform.minimax.io/docs/faq/models)写明套餐请求自 2026-10-19 转路由到 M3.1 Flash；日志的旧 ID 不足以还原实际路由模型，目录只折算所报 ID 的公开价，不推断实际账单。

2026-10-26 核验厂商 USD 标价，新增 Kimi K3.1 Pro / Highspeed / K3、Grok 4.7、Gemini 4 Argon / 3.1 Pro Preview、Qwen3 Coder Flash、GLM 5.3 / Flash / FlashX、MiniMax M3 / M3.1 Flash、MiMo V2.6 Pro UltraSpeed 共 13 条；Gemini 3.8 Flash、Claude Opus 4.6、MiMo V2.6 Pro / Flash 升为官方核验。Kimi Code 别名依据官方模型表与 API 文档对应，套餐标记保留；Opus 4.6 用官方 API ID，thinking 写法保留为别名并补齐一小时缓存写。Grok 的长档从提示达到 200,000 token 起生效；Gemini Pro、Qwen、MiniMax 登记长上下文分档。Qwen 采用新加坡 International 显式缓存费率，隐式缓存费率不同；Google 缓存存储按时长收费，不折成写入 token 单价。Gemini 3.8 Flash 与 4 Argon 采用核验日的公开引入价，到期需重新核验并更新价格版本。未确认身份的 gemini-3.8-flash-n 保留原聚合条目；本地模型与缺模型记录维持未定价。目录变更由现有内容哈希生成新版本，历史账本仅在显式重算时更新估值。
