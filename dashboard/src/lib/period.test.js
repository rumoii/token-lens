import { describe, expect, it } from "vitest";

import {
  bucketKeys,
  currentPeriod,
  periodAxis,
  periodElapsedDays,
  rememberPeriod,
  periodCompare,
  periodGranularity,
  periodRange,
  readPeriod
} from "./period.js";

/** 2026-10-19 是周一。 */
const TODAY = new Date(2026, 9, 19, 15, 30, 0);

describe("period", () => {
  it("本周从周一到今天", () => {
    const range = periodRange({ period: "week" }, TODAY);
    expect(range).toEqual({ from: "2026-10-19", to: "2026-10-19" });
  });

  it("本周对比上周同期，不是整周", () => {
    const compare = periodCompare({ period: "week" }, new Date(2026, 9, 21, 10, 0, 0));
    // 10-21 是周三，本周一到周三；上周一 10-12 到上周三 10-14
    expect(compare).toEqual({ from: "2026-10-12", to: "2026-10-14", label: "上周" });
  });

  it("本月对比上月同日，上月没有这天就用月末", () => {
    const march31 = periodCompare({ period: "month" }, new Date(2026, 2, 31));
    expect(march31.to).toBe("2026-02-28");
  });

  it("全部与自定义没有对比", () => {
    expect(periodCompare({ period: "all" }, TODAY)).toBeNull();
    expect(periodCompare({ period: "custom", from: "2026-10-01", to: "2026-10-02" }, TODAY)).toBeNull();
  });

  it("周期从 URL 读，缺省为本周", () => {
    expect(readPeriod("").period).toBe("week");
    expect(readPeriod("?period=month").period).toBe("month");
    expect(readPeriod("?period=nonsense").period).toBe("week");
  });
});

describe("bucketKeys", () => {
  it("小时：今天 0 点到 23 点共 24 个槽", () => {
    const keys = bucketKeys("hour", { from: "2026-10-19", to: "2026-10-19" }, TODAY);
    expect(keys).toHaveLength(24);
    expect(keys[0]).toBe("2026-10-19T00:00:00");
    expect(keys[23]).toBe("2026-10-19T23:00:00");
  });

  it("按天：范围每天一个槽，顺序递增", () => {
    const keys = bucketKeys("day", { from: "2026-10-19", to: "2026-10-23" }, TODAY);
    expect(keys).toEqual([
      "2026-10-19",
      "2026-10-20",
      "2026-10-21",
      "2026-10-22",
      "2026-10-23"
    ]);
  });

  it("按天：本周只有一天时就是一天", () => {
    expect(bucketKeys("day", { from: "2026-10-19", to: "2026-10-19" }, TODAY)).toEqual(["2026-10-19"]);
  });

  it("按月：跨年也连续", () => {
    const keys = bucketKeys("month", { from: "2025-11-15", to: "2026-02-03" }, TODAY);
    expect(keys).toEqual(["2025-11", "2025-12", "2026-01", "2026-02"]);
  });

  it("范围为空时不凭空造时间轴", () => {
    expect(bucketKeys("day", { from: null, to: null }, TODAY)).toEqual([]);
    expect(bucketKeys("month", { from: null, to: null }, TODAY)).toEqual([]);
  });

  it("粒度决定桶的形态", () => {
    const p = { period: "today", from: "2026-10-19", to: "2026-10-19" };
    expect(periodGranularity(p)).toBe("hour");
    expect(periodGranularity({ period: "week" })).toBe("day");
    expect(periodGranularity({ period: "all" })).toBe("month");
  });
});

describe("periodElapsedDays", () => {
  it("只算到今天：周一看本周是 1 天，19 号看本月是 19 天", () => {
    expect(periodElapsedDays({ period: "week" }, TODAY)).toBe(1);
    expect(periodElapsedDays({ period: "week" }, new Date(2026, 9, 25))).toBe(7);
    expect(periodElapsedDays({ period: "month" }, TODAY)).toBe(19);
    expect(periodElapsedDays({ period: "today" }, TODAY)).toBe(1);
  });

  it("全部从最早记录算，自定义按区间", () => {
    expect(periodElapsedDays({ period: "all" }, TODAY, "2026-10-17T02:00:00")).toBe(3);
    expect(periodElapsedDays({ period: "custom", from: "2026-10-01", to: "2026-10-10" }, TODAY)).toBe(10);
  });
});

describe("periodAxis", () => {
  it("本周固定周一到周日，本月固定整月", () => {
    expect(periodAxis({ period: "week" }, TODAY)).toEqual({ granularity: "day", from: "2026-10-19", to: "2026-10-25" });
    expect(periodAxis({ period: "month" }, TODAY)).toEqual({ granularity: "day", from: "2026-10-01", to: "2026-10-31" });
    expect(periodAxis({ period: "today" }, TODAY).granularity).toBe("hour");
  });

  it("全部：跨度短按天，长了按月", () => {
    expect(periodAxis({ period: "all" }, TODAY, "2026-10-17T02:00:00")).toEqual({
      granularity: "day",
      from: "2026-10-17",
      to: "2026-10-19"
    });
    expect(periodAxis({ period: "all" }, TODAY, "2025-11-01T00:00:00").granularity).toBe("month");
    expect(periodAxis({ period: "all" }, TODAY, null)).toEqual({ granularity: "month", from: null, to: null });
  });
});

describe("currentPeriod / rememberPeriod", () => {
  it("URL 没带周期时沿用记住的，URL 带了以 URL 为准", () => {
    window.localStorage.clear();
    expect(currentPeriod("").period).toBe("week");
    rememberPeriod({ period: "custom", from: "2026-10-01", to: "2026-10-05" });
    expect(currentPeriod("")).toEqual({ period: "custom", from: "2026-10-01", to: "2026-10-05" });
    expect(currentPeriod("?period=today").period).toBe("today");
    window.localStorage.clear();
  });
});
