import React from "react";

const TONES = {
  neutral: "bg-[var(--lens-fill-hover)] text-ink-secondary",
  clay: "bg-clay-wash text-clay",
  ok: "bg-[var(--lens-fill-hover)] text-signal-ok",
  warn: "bg-[var(--lens-fill-hover)] text-signal-warn",
  danger: "bg-[var(--lens-fill-hover)] text-signal-danger"
};

/**
 * 行内徽标。高度只有 20px，用在表格与列表里不撑行。
 *
 * @param {{ children: React.ReactNode, tone?: keyof typeof TONES, title?: string }} props
 */
export function Badge({ children, tone = "neutral", title }) {
  return (
    <span
      title={title}
      className={`inline-flex h-5 items-center rounded-sm px-1.5 text-micro font-medium uppercase tracking-wide ${TONES[tone] || TONES.neutral}`}
    >
      {children}
    </span>
  );
}

/** 价格状态：这个金额可信到什么程度。 */
const PRICE_STATE = {
  verified: { label: "已核验", tone: "ok", title: "价格来自厂商官方页" },
  aggregate: { label: "聚合估算", tone: "warn", title: "价格来自聚合库或公开市场价，未在厂商页核验" },
  unknown: { label: "未定价", tone: "neutral", title: "没有找到该模型的价格" }
};

/** 计费方式：我实际怎么付钱。与价格状态是两件事。 */
const BILLING = {
  metered: { label: "按量", tone: "neutral", title: "按公开标准价计费" },
  plan: { label: "套餐", tone: "clay", title: "厂商按套餐售卖；金额是这些 token 的公开市场价折算，不是你的账单" }
};

/**
 * @param {{ state?: keyof typeof PRICE_STATE }} props
 */
export function PriceStateBadge({ state }) {
  const meta = PRICE_STATE[state] || PRICE_STATE.unknown;
  return <Badge tone={meta.tone} title={meta.title}>{meta.label}</Badge>;
}

/**
 * @param {{ billing?: keyof typeof BILLING }} props
 */
export function BillingBadge({ billing }) {
  const meta = BILLING[billing] || BILLING.metered;
  return <Badge tone={meta.tone} title={meta.title}>{meta.label}</Badge>;
}

export const PRICE_STATE_LABEL = (state) => (PRICE_STATE[state] || PRICE_STATE.unknown).label;
export const PRICE_STATE_TITLE = (state) => (PRICE_STATE[state] || PRICE_STATE.unknown).title;
export const BILLING_TITLE = (billing) => (BILLING[billing] || BILLING.metered).title;
