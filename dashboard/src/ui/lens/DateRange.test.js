import { describe, expect, test } from "vitest";
import { granularityForRange, spanDaysOf } from "./DateRange.jsx";

const today = () => new Date().toISOString().slice(0, 10);

describe("spanDaysOf", () => {
  test("两端都空是全部时间，跨度无界", () => {
    expect(spanDaysOf({ from: "", to: "" })).toBeNull();
  });

  test("今天的预设（from=今天，to 空）是 1 天", () => {
    expect(spanDaysOf({ from: today(), to: "" })).toBe(1);
  });

  test("同一天的自定义区间也是 1 天", () => {
    expect(spanDaysOf({ from: "2026-10-19", to: "2026-10-19" })).toBe(1);
  });

  test("区间天数含首尾", () => {
    expect(spanDaysOf({ from: "2026-10-18", to: "2026-10-19" })).toBe(2);
    expect(spanDaysOf({ from: "2026-09-20", to: "2026-10-19" })).toBe(30);
  });
});

describe("granularityForRange", () => {
  test("单日按小时", () => {
    expect(granularityForRange({ from: today(), to: "" })).toBe("hour");
    expect(granularityForRange({ from: "2026-10-19", to: "2026-10-19" })).toBe("hour");
  });

  test("90 天内按日，更长按月", () => {
    expect(granularityForRange({ from: "2026-09-20", to: "2026-10-19" })).toBe("day");
    expect(granularityForRange({ from: "2026-07-22", to: "2026-10-19" })).toBe("day");
    expect(granularityForRange({ from: "2026-07-21", to: "2026-10-19" })).toBe("month");
  });

  test("全部时间按月", () => {
    expect(granularityForRange({ from: "", to: "" })).toBe("month");
  });
});
