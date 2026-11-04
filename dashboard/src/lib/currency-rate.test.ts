import { describe, expect, test } from "vitest";
import { CURRENCY_CNY, DEFAULT_RATES } from "./currency";
import { formatUsdCurrency } from "./format";

describe("固定折算率（暂用）", () => {
  test("CNY 折算率是 6.7，写在 DEFAULT_RATES 一处", () => {
    expect(DEFAULT_RATES.CNY).toBe(6.7);
  });

  test("金额按折算率换算并带人民币符号", () => {
    expect(formatUsdCurrency("10.00", { currency: CURRENCY_CNY, rate: DEFAULT_RATES.CNY })).toBe(
      "¥67.00"
    );
  });

  test("USD 原样显示，即使误传折算率也不乘", () => {
    expect(formatUsdCurrency("10.00")).toBe("$10.00");
    expect(formatUsdCurrency("10.00", { currency: "USD", rate: DEFAULT_RATES.CNY })).toBe("$10.00");
  });

  test("空值不当 0 处理", () => {
    expect(formatUsdCurrency(null, { currency: CURRENCY_CNY, rate: DEFAULT_RATES.CNY })).toBe("-");
    expect(formatUsdCurrency("  ", { currency: CURRENCY_CNY, rate: DEFAULT_RATES.CNY })).toBe("-");
  });
});
