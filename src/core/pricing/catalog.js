import { createHash } from 'node:crypto';

/** 日志提供方 ID；依据与字段位置见 specs/log-schemas.yaml，不按模型名猜测。 */
export const LOCAL_PROVIDERS = Object.freeze(['ollama', 'lmstudio']);

/** @param {string|null|undefined} provider @returns {string|null} 目录里的标准小写 ID */
export function localProvider(provider) {
  const id = typeof provider === 'string' ? provider.toLowerCase() : null;
  return LOCAL_PROVIDERS.includes(id) ? id : null;
}

/**
 * 价格目录。
 *
 * 只收**逐条核验过的官方标准价**。查不到就是未定价（`cost_micros = null`），
 * 不用家族正则猜，也不拿近似型号顶替。
 *
 * 单位：USD / 1M tokens。
 * `cacheWrite: null` 表示该模型不单独对缓存写入计价。
 *
 * 核验台账见 archive 里的 pricing-verification.md：来源 URL、抓取日期、计费条件。
 */
const SOURCE_ANTHROPIC = 'https://platform.claude.com/docs/en/about-claude/pricing';
const SOURCE_OPENAI = 'https://developers.openai.com/api/docs/pricing';
const SOURCE_DEEPSEEK = 'https://api-docs.deepseek.com/quick_start/pricing';
const SOURCE_MODELS_DEV = 'https://models.dev/api.json';
const SOURCE_KIMI = 'https://platform.kimi.ai/docs/pricing/chat';
const SOURCE_XAI = 'https://docs.x.ai/developers/pricing';
const SOURCE_GOOGLE = 'https://ai.google.dev/gemini-api/docs/pricing';
const SOURCE_QWEN = 'https://docs.modelstudio.console.alibabacloud.com/en/model-studio/qwen3-coder-flash';
const SOURCE_GLM = 'https://docs.z.ai/guides/overview/pricing';
const SOURCE_MINIMAX = 'https://platform.minimax.io/docs/pricing/overview';
const SOURCE_MINIMAX_M27 = 'https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise';
const SOURCE_MIMO = 'https://mimo.mi.com/docs/en-US/price/pay-as-you-go';
const VERIFIED_AT = '2026-10-18';
const SOURCE_CN_HOLIDAYS_2026 = 'https://www.gov.cn/zhengce/content/202511/content_7047090.htm';
const WEEKDAYS = [1, 2, 3, 4, 5];

/** 闭区间内的每一天，YYYY-MM-DD。 */
function days(from, to) {
  const out = [];
  for (let t = Date.parse(`${from}T00:00:00Z`); t <= Date.parse(`${to}T00:00:00Z`); t += 86_400_000) {
    out.push(new Date(t).toISOString().slice(0, 10));
  }
  return out;
}

/** 中国法定节假日放假日（国务院办公厅放假安排，含调休放假的工作日；补班日不在其中）。来源 SOURCE_CN_HOLIDAYS_2026。 */
const HOLIDAYS_CN = [
  ...days('2026-01-01', '2026-01-03'), ...days('2026-02-15', '2026-02-23'), ...days('2026-04-04', '2026-04-06'),
  ...days('2026-05-01', '2026-05-05'), ...days('2026-06-19', '2026-06-21'), ...days('2026-09-25', '2026-09-27'),
  ...days('2026-10-01', '2026-10-07')
];

const LONG_CONTEXT_OPENAI =
  'Standard；单次请求输入（含缓存命中与缓存写）超过 272K token 时整条请求按长上下文档计价；缓存写取 30 分钟档';

const ENTRIES = [
  // ---------------- Anthropic ----------------
  {
    id: 'claude-fable-5-1',
    aliases: ['claude-fable-5.1'],
    perMTok: { input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWrite1h: 20 },
    sourceUrl: SOURCE_ANTHROPIC,
    conditions: '标准按需；缓存写分 5 分钟档（12.50）与 1 小时档（20.00），按实际上报档位计价'
  },
  {
    id: 'claude-opus-5-5',
    aliases: ['claude-opus-5.5'],
    perMTok: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWrite1h: 8 },
    sourceUrl: SOURCE_ANTHROPIC,
    conditions: '标准按需；缓存写分 5 分钟档（5.00）与 1 小时档（8.00），按实际上报档位计价'
  },
  {
    id: 'claude-sonnet-5-5',
    aliases: ['claude-sonnet-5.5'],
    perMTok: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, cacheWrite1h: 4 },
    sourceUrl: SOURCE_ANTHROPIC,
    conditions: '标准按需；缓存写分 5 分钟档（2.50）与 1 小时档（4.00），按实际上报档位计价'
  },
  {
    id: 'claude-haiku-5-5',
    aliases: ['claude-haiku-5.5'],
    perMTok: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, cacheWrite1h: 0.2 },
    tiers: [{ above: 100_000, perMTok: { input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625, cacheWrite1h: 1 } }],
    sourceUrl: SOURCE_ANTHROPIC,
    verifiedAt: '2026-10-26',
    conditions: '标准按需；单次请求的提示（含缓存读写）超过 100,000 token 时整条请求按高档计价'
  },
  {
    id: 'claude-mythos-5-1',
    aliases: ['claude-mythos-5.1'],
    perMTok: { input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWrite1h: 20 },
    sourceUrl: SOURCE_ANTHROPIC,
    conditions: '标准按需；缓存写分 5 分钟档（12.50）与 1 小时档（20.00），按实际上报档位计价'
  },

  // ---------------- OpenAI ----------------
  {
    id: 'gpt-6.1-sol',
    aliases: ['gpt-6-1-sol'],
    perMTok: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5 },
    tiers: [{ above: 272_000, perMTok: { input: 4, output: 15, cacheRead: 0.2, cacheWrite: 5 } }],
    sourceUrl: SOURCE_OPENAI,
    verifiedAt: '2026-10-26',
    conditions: LONG_CONTEXT_OPENAI
  },
  {
    id: 'gpt-6-sol',
    aliases: [],
    perMTok: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 },
    tiers: [{ above: 272_000, perMTok: { input: 4, output: 15, cacheRead: 0.4, cacheWrite: 5 } }],
    sourceUrl: SOURCE_OPENAI,
    verifiedAt: '2026-10-26',
    conditions: LONG_CONTEXT_OPENAI
  },
  {
    id: 'gpt-6-astra',
    aliases: [],
    perMTok: { input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5 },
    tiers: [{ above: 272_000, perMTok: { input: 20, output: 75, cacheRead: 2, cacheWrite: 25 } }],
    sourceUrl: SOURCE_OPENAI,
    verifiedAt: '2026-10-26',
    conditions: LONG_CONTEXT_OPENAI
  },
  {
    id: 'gpt-6-luna',
    aliases: [],
    perMTok: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125 },
    tiers: [{ above: 272_000, perMTok: { input: 0.2, output: 0.75, cacheRead: 0.02, cacheWrite: 0.25 } }],
    sourceUrl: SOURCE_OPENAI,
    verifiedAt: '2026-10-26',
    conditions: LONG_CONTEXT_OPENAI
  },
  {
    id: 'gpt-5.3-codex',
    aliases: [],
    perMTok: { input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: null },
    sourceUrl: SOURCE_OPENAI,
    conditions: 'Standard；文档未列缓存写费率'
  },

  // ---------------- DeepSeek ----------------
  {
    id: 'deepseek-flash',
    aliases: ['deepseek-v4-flash'],
    perMTok: { input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: null },
    timeOfDay: {
      utcOffsetMinutes: 480,
      peak: [{ days: WEEKDAYS, from: 9 * 60, to: 12 * 60 }, { days: WEEKDAYS, from: 14 * 60, to: 18 * 60 }],
      offPeak: { input: 0.15, output: 0.6, cacheRead: 0.003, cacheWrite: null },
      holidays: HOLIDAYS_CN
    },
    sourceUrl: SOURCE_DEEPSEEK,
    verifiedAt: '2026-10-26',
    conditions:
      '峰谷分时：北京时间周一至周五 9:00-12:00、14:00-18:00 为高峰（基础价），其余时段、周末与中国法定节假日全天为低谷（半价）。' +
      '节假日按国务院办公厅放假安排的放假日计（目前登记 2026 年，未登记年份的节假日按工作日处理）；周末补班日按周末计'
  },

  // ---------------- Kimi ----------------
  {
    id: 'kimi-k3.1-pro',
    aliases: ['k3.1-pro', 'kimi-code/k3.1-pro'],
    perMTok: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2, cacheWrite1h: 4 },
    sourceUrl: SOURCE_KIMI,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: 'Kimi API 国际 USD 标准价，全 1M 上下文统一费率；缓存写分 5 分钟与 1 小时档，未拆分时取 5 分钟。' +
      'Kimi Code 模型表将 k3.1-pro 标为 K3.1 Pro，官方发布页 https://www.kimi.ai/blog/kimi-k3-1-pro 将同一模型的 API ID 列为 kimi-k3.1-pro；' +
      '套餐对应依据：https://www.kimi.com/code/docs/kimi-code/models.html；金额按 API 市场价折算，不是套餐账单'
  },
  {
    id: 'kimi-k3.1-pro-highspeed',
    aliases: ['k3.1-pro-highspeed', 'kimi-code/k3.1-pro-highspeed'],
    perMTok: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 4, cacheWrite1h: 8 },
    sourceUrl: SOURCE_KIMI,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: 'Kimi API 国际 USD Highspeed 标准价，全 1M 上下文统一费率；缓存写分 5 分钟与 1 小时档，未拆分时取 5 分钟。' +
      'https://www.kimi.com/code/docs/kimi-code/models.html 将 k3.1-pro-highspeed 标为 K3.1 Pro Highspeed；' +
      'https://www.kimi.ai/blog/kimi-k3-1-pro 将同一模型的 API ID 列为 kimi-k3.1-pro-highspeed；套餐按 API 市场价折算'
  },
  {
    id: 'kimi-k3',
    aliases: ['k3', 'kimi-code/k3'],
    perMTok: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3, cacheWrite1h: 6 },
    sourceUrl: SOURCE_KIMI,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: 'Kimi API 国际 USD 标准价，全 1M 上下文统一费率；缓存写分 5 分钟与 1 小时档，未拆分时取 5 分钟。' +
      'https://www.kimi.com/code/docs/kimi-code/models.html 将 k3 标为 K3；' +
      'https://platform.kimi.ai/docs/guide/kimi-k3-quickstart 给出 API ID kimi-k3；不合并 k3-256k，套餐按 API 市场价折算'
  },

  // ---------------- xAI ----------------
  {
    id: 'grok-4.7',
    aliases: [],
    perMTok: { input: 2, output: 6, cacheRead: 0.5, cacheWrite: null },
    tiers: [{ above: 199_999, perMTok: { input: 4, output: 12, cacheRead: 1, cacheWrite: null } }],
    sourceUrl: SOURCE_XAI,
    verifiedAt: '2026-10-26',
    conditions: '全球端点标准价；提示达到 200,000 token（含缓存读写）整条请求按高档，above:199999 表示 >=200000；' +
      '官网未单列缓存写 token 费率；不含 Batch 折扣、Fast 服务或 US 区域端点 10% 加价'
  },

  // ---------------- Google ----------------
  {
    id: 'gemini-3.8-flash',
    aliases: [],
    perMTok: { input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: null },
    sourceUrl: SOURCE_GOOGLE,
    verifiedAt: '2026-10-26',
    conditions: 'Standard，2026-12-31 前的公开引入价；2027-01-01 起输入/输出/缓存读为 1.50/7.50/0.15，需另核验更新目录。' +
      '官网未单列缓存写 token 费率；缓存存储另按 $0.50/1M token/小时计，不折算成缓存写价；不含 Batch、Flex、Priority 或工具费'
  },
  {
    id: 'gemini-4-argon',
    aliases: [],
    perMTok: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: null },
    sourceUrl: SOURCE_GOOGLE,
    verifiedAt: '2026-10-26',
    conditions: 'Standard，2026-11-30 前的公开引入价；2026-12-01 起输入/输出/缓存读为 4/20/0.20，需另核验更新目录。' +
      '仅隐式缓存，官网未单列缓存写 token 费率；不含 Batch、Flex、Priority 或工具费'
  },
  {
    id: 'gemini-3.1-pro-preview',
    aliases: [],
    perMTok: { input: 2, output: 12, cacheRead: 0.2, cacheWrite: null },
    tiers: [{ above: 200_000, perMTok: { input: 4, output: 18, cacheRead: 0.4, cacheWrite: null } }],
    sourceUrl: SOURCE_GOOGLE,
    verifiedAt: '2026-10-26',
    conditions: 'Standard；提示超过 200,000 token（含缓存读写）整条请求按高档；官网未单列缓存写 token 费率。' +
      '缓存存储另按 $4.50/1M token/小时计，不折算成缓存写价；不含 Batch、Flex 或工具费'
  },

  // ---------------- 聚合来源（未在厂商页核验） ----------------
  {
    id: 'gemini-3.8-flash-n',
    aliases: [],
    perMTok: { input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.08333 },
    sourceUrl: SOURCE_MODELS_DEV,
    tier: 'aggregate',
    conditions: '同 gemini-3.8-flash；`-n` 变体未在官方页确认，按同系列取值'
  },

  // ---------------- Anthropic（既有版本） ----------------
  {
    id: 'claude-opus-4-6',
    aliases: ['claude-opus-4-6-thinking'],
    perMTok: { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10 },
    sourceUrl: SOURCE_ANTHROPIC,
    verifiedAt: '2026-10-26',
    conditions: '官方 API ID claude-opus-4-6；thinking 是同一模型的扩展思考模式，不是另一个型号。' +
      '标准按需，全 1M 上下文统一费率；缓存写分 5 分钟与 1 小时档，未拆分时取 5 分钟；不含 Batch、US 区域加价或工具费'
  },

  // ---------------- Qwen ----------------
  {
    id: 'qwen3-coder-flash',
    aliases: [],
    perMTok: { input: 0.3, output: 1.5, cacheRead: 0.03, cacheWrite: 0.375 },
    tiers: [
      { above: 32_000, perMTok: { input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625 } },
      { above: 128_000, perMTok: { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 } },
      { above: 256_000, perMTok: { input: 1.6, output: 9.6, cacheRead: 0.16, cacheWrite: 2 } }
    ],
    sourceUrl: SOURCE_QWEN,
    verifiedAt: '2026-10-26',
    conditions: '新加坡 International USD 标准价，显式缓存 5 分钟档；提示（含缓存读写）按 32k/128k/256k 分档，k 按十进制千计。' +
      '隐式缓存命中费率为各档输入的 20%，此条目仅取显式缓存费率；模式不能混算。' +
      '快照版本不支持相同的缓存能力，未作别名；不含其他地区或限时优惠'
  },

  // ---------------- GLM ----------------
  {
    id: 'glm-5.3',
    aliases: [],
    perMTok: { input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: null },
    sourceUrl: SOURCE_GLM,
    verifiedAt: '2026-10-26',
    conditions: 'Z.AI 国际 USD 按量价；缓存存储限时免费，官网未单列缓存写 token 费率；不套用 Coding Plan 的峰谷积分折扣'
  },
  {
    id: 'glm-5.3-flash',
    aliases: [],
    perMTok: { input: 0.15, output: 0.5, cacheRead: 0.03, cacheWrite: null },
    sourceUrl: SOURCE_GLM,
    verifiedAt: '2026-10-26',
    conditions: 'Z.AI 国际 USD 按量价；缓存存储限时免费，官网未单列缓存写 token 费率；不套用 Coding Plan 的峰谷积分折扣'
  },
  {
    id: 'glm-5.3-flashx',
    aliases: [],
    perMTok: { input: 0.37, output: 1.25, cacheRead: 0.075, cacheWrite: null },
    sourceUrl: SOURCE_GLM,
    verifiedAt: '2026-10-26',
    conditions: 'Z.AI 国际 USD 按量价；缓存存储限时免费，官网未单列缓存写 token 费率；不与 Flash 或 Legal 版本合并'
  },

  // ---------------- MiniMax ----------------
  {
    id: 'MiniMax-M2.7',
    aliases: [],
    perMTok: { input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.375 },
    sourceUrl: SOURCE_MINIMAX_M27,
    verifiedAt: '2026-11-01',
    tier: 'aggregate',
    conditions: '国际 USD API Pricing 公开价；依据官方价目页的旧搜索快照，快照日期未知（2026-11-01 搜索索引仅显示上月抓取）；verifiedAt 为快照复核日期，不代表当日官网核验。原页已跳转到不再列出 M2.7 的价目总览，M2.7 官网标为退役，实时价格未确认。' +
      '快照未列长上下文分档、峰谷价或缓存写时长分档，不推定独立 1 小时写入价；仅按日志所报 ID 折算，不推断套餐请求转路由后的实际模型'
  },
  {
    id: 'MiniMax-M2.7-highspeed',
    aliases: [],
    perMTok: { input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375 },
    sourceUrl: SOURCE_MINIMAX_M27,
    verifiedAt: '2026-11-01',
    tier: 'aggregate',
    conditions: '国际 USD API Pricing Highspeed 公开价；依据官方价目页的旧搜索快照，快照日期未知（2026-11-01 搜索索引仅显示上月抓取）；verifiedAt 为快照复核日期，不代表当日官网核验。原页已跳转到不再列出 M2.7 的价目总览，M2.7 官网标为退役，实时价格未确认。' +
      '缓存读写与 M2.7 同价；快照未列长上下文分档、峰谷价或缓存写时长分档，不推定独立 1 小时写入价；不与标准版合并'
  },
  {
    id: 'MiniMax-M3',
    aliases: [],
    perMTok: { input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: null },
    tiers: [{ above: 512_000, perMTok: { input: 0.6, output: 2.4, cacheRead: 0.12, cacheWrite: null } }],
    sourceUrl: SOURCE_MINIMAX,
    verifiedAt: '2026-10-26',
    conditions: 'Standard，官网 Permanent 50% off 后的公开售价；提示（含缓存读写）超过 512k token 整条请求按高档，k 按十进制千计。' +
      '官网未单列缓存写 token 费率；不含 Priority 的 1.5 倍服务价'
  },
  {
    id: 'MiniMax-M3.1-Flash',
    aliases: [],
    perMTok: { input: 0.15, output: 0.6, cacheRead: 0.015, cacheWrite: null },
    sourceUrl: SOURCE_MINIMAX,
    verifiedAt: '2026-10-26',
    conditions: '国际 USD 按量标准价；官网未单列缓存写 token 费率；不将 Flash-Preview 或免费网关版本作别名'
  },

  // ---------------- MiMo（套餐按 API 市场价折算） ----------------
  {
    id: 'mimo-v2.6-pro',
    aliases: [],
    perMTok: { input: 0.435, output: 0.87, cacheRead: 0.0036, cacheWrite: null },
    sourceUrl: SOURCE_MIMO,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: '官方海外 Real-time API USD 标准价；缓存写限时免费，未单列按 token 的写入费率；套餐按 API 市场价折算，API 余额与套餐额度独立；不含 Batch 折扣'
  },
  {
    id: 'mimo-v2.6-flash',
    aliases: [],
    perMTok: { input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: null },
    sourceUrl: SOURCE_MIMO,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: '官方海外 Real-time API USD 标准价；缓存写限时免费，未单列按 token 的写入费率；套餐按 API 市场价折算，API 余额与套餐额度独立；不含 Batch 折扣'
  },
  {
    id: 'mimo-v2.6-pro-ultraspeed',
    aliases: [],
    perMTok: { input: 4.35, output: 8.7, cacheRead: 0.036, cacheWrite: null },
    sourceUrl: SOURCE_MIMO,
    verifiedAt: '2026-10-26',
    billing: 'plan',
    conditions: '官方海外 Real-time API USD UltraSpeed 标准价；缓存写限时免费，未单列按 token 的写入费率；套餐按 API 市场价折算，API 余额与套餐额度独立；不支持 Batch'
  }
].map((e) => ({
  ...e,
  currency: 'USD',
  verifiedAt: e.verifiedAt || VERIFIED_AT,
  tier: e.tier || 'verified',
  billing: e.billing || 'metered',
  provisional: (e.tier || 'verified') !== 'verified'
}));

/**
 * 计费方式标记（不影响价格查找）。
 *
 * `metered`：按量计费；`plan`：厂商按套餐售卖，金额是市场价折算。
 * 界面用它解释「为什么有金额但我没按这个付钱」。
 */
export const BILLING = {
  metered: { label: '按量计费', hint: '按公开标准价计费' },
  plan: { label: '套餐制', hint: '厂商按套餐售卖；金额是这些 token 的公开市场价折算，不是你的账单' }
};

/**
 * 长上下文分档：`above` 为正整数且严格递增，每档的输入、输出、缓存读单价齐全。
 * 写错就在加载时报错，不让错误的价表进入计算。
 * @param {Object} entry
 */
function checkTiers(entry) {
  if (entry.tiers === undefined) return;
  if (!Array.isArray(entry.tiers) || entry.tiers.length === 0) throw new Error(`价格条目 ${entry.id} 的 tiers 必须是非空数组`);
  let previous = 0;
  for (const tier of entry.tiers) {
    if (!Number.isInteger(tier.above) || tier.above <= previous) {
      throw new Error(`价格条目 ${entry.id} 的 tiers.above 必须是严格递增的正整数`);
    }
    for (const key of ['input', 'output', 'cacheRead']) {
      if (typeof tier.perMTok?.[key] !== 'number') throw new Error(`价格条目 ${entry.id} 的分档缺少 ${key} 单价`);
    }
    previous = tier.above;
  }
}
/**
 * 峰谷分时：固定 UTC 偏移（不依赖机器时区），高峰时段按当地星期（0 为周日）与分钟 [from, to)，
 * 低谷单价齐全，节假日为合法日期。同一条目不能同时写分档。
 * @param {Object} entry
 */
function checkTimeOfDay(entry) {
  const tod = entry.timeOfDay;
  if (tod === undefined) return;
  const fail = (what) => { throw new Error(`价格条目 ${entry.id} 的 timeOfDay ${what}`); };
  if (entry.tiers !== undefined) fail('不能与 tiers 同时写');
  if (!Number.isInteger(tod.utcOffsetMinutes) || Math.abs(tod.utcOffsetMinutes) > 14 * 60) fail('utcOffsetMinutes 无效');
  if (!Array.isArray(tod.peak) || tod.peak.length === 0) fail('peak 必须是非空数组');
  for (const w of tod.peak) {
    if (!Array.isArray(w.days) || w.days.length === 0 || !w.days.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) fail('peak.days 必须是 0–6');
    if (!Number.isInteger(w.from) || !Number.isInteger(w.to) || w.from < 0 || w.to > 1440 || w.from >= w.to) fail('peak 的起止分钟无效');
  }
  for (const key of ['input', 'output', 'cacheRead']) {
    if (typeof tod.offPeak?.[key] !== 'number') fail(`offPeak 缺少 ${key} 单价`);
  }
  if (!Array.isArray(tod.holidays)) fail('holidays 必须是数组');
  for (const day of tod.holidays) {
    const t = Date.parse(`${day}T00:00:00Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(t) || new Date(t).toISOString().slice(0, 10) !== day) fail(`节假日 ${day} 不是合法日期`);
  }
}

/** 加载时逐条校验分档与峰谷，价表写错直接报错。 */
export function checkEntry(entry) {
  checkTiers(entry);
  checkTimeOfDay(entry);
}
for (const entry of ENTRIES) checkEntry(entry);

/** 精确 ID 与前缀归一化后的别名索引。 */
const INDEX = new Map();
for (const entry of ENTRIES) {
  INDEX.set(entry.id.toLowerCase(), entry);
  for (const alias of entry.aliases) INDEX.set(alias.toLowerCase(), entry);
}

export const CATALOG = ENTRIES;

/**
 * 价格版本 = 目录内容哈希（单价、分档、峰谷与节假日、核验日期、来源分级、计费方式、本地提供方）。换目录即换版本，历史估值可据此重算。
 * @param {Array<Object>} entries
 * @param {string[]} [localProviders]
 * @returns {string}
 */
export function versionOf(entries, localProviders = LOCAL_PROVIDERS) {
  return createHash('sha256')
    .update(JSON.stringify([entries.map((e) => [e.id, e.perMTok, e.verifiedAt, e.tier, e.tiers ?? null, e.timeOfDay ?? null, e.billing]), localProviders]))
    .digest('hex')
    .slice(0, 16);
}

export const PRICE_VERSION = versionOf(ENTRIES);

/** 推理档位后缀：同一模型的推理强度，不改变单价。 */
const REASONING_SUFFIX = /-(xhigh|high|medium|low|fast|thinking)$/;

/**
 * 把模型名收敛成目录里的写法。
 *
 * 只处理**同一个模型的不同书写方式**：大小写、括号限定词、空白与下划线、
 * provider 前缀、推理档位后缀、版本号的点与连字符。
 *
 * 不做家族模糊匹配。`gpt-6-sol` 与 `gpt-6.1-sol` 是不同价位的两个模型，
 * 把它们合并等于拿不确认的价当确认的用。
 *
 * @param {string} raw
 * @returns {string[]} 候选键，越靠前越可信
 */
function normalizedCandidates(raw) {
  let name = String(raw).trim().toLowerCase();
  name = name.replace(/\([^)]*\)/g, ' ');          // (Preview)、（思考）之类的限定词
  name = name.replace(/[\s_]+/g, '-');             // 空白与下划线统一成连字符
  name = name.replace(/^(?:[a-z0-9.-]+\/)+/, '');   // provider 前缀：openrouter/anthropic/claude-…
  name = name.replace(/-{2,}/g, '-').replace(/^-+|-+$/g, '');

  const bases = [name, name.replace(REASONING_SUFFIX, '')];
  const out = [];
  for (const base of bases) {
    if (!base) continue;
    for (const variant of [
      base,
      base.replace(/(\d)\.(\d)/g, '$1-$2'),
      base.replace(/(\d)-(\d)/g, '$1.$2')
    ]) {
      if (variant && !out.includes(variant)) out.push(variant);
    }
  }
  return out;
}

/**
 * @param {Object} entry 目录条目
 * @param {'exact'|'normalized'} matchedBy
 * @returns {Object}
 */
function toPrice(entry, matchedBy) {
  return {
    perMTok: entry.perMTok,
    tiers: entry.tiers ?? null,
    timeOfDay: entry.timeOfDay ?? null,
    provisional: entry.provisional,
    tier: entry.tier,
    billing: entry.billing,
    id: entry.id,
    sourceUrl: entry.sourceUrl,
    verifiedAt: entry.verifiedAt,
    conditions: entry.conditions,
    matchedBy
  };
}

/**
 * 按模型名查价。
 *
 * 先精确匹配（含目录里登记的别名），再试归一化写法。归一化只覆盖同一模型的
 * 不同书写方式，找到时 `matchedBy` 为 `normalized`；查不到仍然返回 null（未定价）。
 *
 * @param {string|null|undefined} model
 * @returns {{ perMTok: {input:number, output:number, cacheRead:number, cacheWrite:number|null},
 *             provisional: boolean, tier: string, billing: string, id: string,
 *             sourceUrl?: string, verifiedAt?: string, conditions?: string,
 *             matchedBy: 'exact'|'normalized' }|null}
 */
export function findPrice(model) {
  if (!model || typeof model !== 'string') return null;

  const key = model.trim().toLowerCase();
  const exact = INDEX.get(key);
  if (exact) return toPrice(exact, 'exact');

  for (const candidate of normalizedCandidates(model)) {
    if (candidate === key) continue;
    const hit = INDEX.get(candidate);
    if (hit) return toPrice(hit, 'normalized');
  }

  return null;
}

/**
 * 模型的价格状态。界面据此区分四种情况，而不是一律显示「未定价」。
 *
 * - `verified`：官方页逐条核验
 * - `aggregate`：聚合库或市场价，未在厂商页核验
 * - `unknown`：没有价格信息
 *
 * 另返回 `billing`：`metered` 按量计费 / `plan` 套餐制（金额为市场价折算）。
 * 与 `findPrice` 走同一条匹配链，避免「查得到价但状态是未定价」这种自相矛盾。
 *
 * @param {string|null|undefined} model
 * @returns {{ state: 'verified'|'aggregate'|'unknown', billing: 'metered'|'plan',
 *             id: string|null, sourceUrl: string|null, note: string|null, provisional: boolean,
 *             matchedBy: 'exact'|'normalized'|null }}
 */
export function classifyPrice(model) {
  const price = findPrice(model);
  if (price) {
    return {
      state: price.tier,
      billing: price.billing || 'metered',
      id: price.id,
      sourceUrl: price.sourceUrl || null,
      note: price.conditions || null,
      provisional: price.provisional,
      matchedBy: price.matchedBy
    };
  }
  return {
    state: 'unknown',
    billing: 'metered',
    id: null,
    sourceUrl: null,
    note: null,
    provisional: false,
    matchedBy: null
  };
}

