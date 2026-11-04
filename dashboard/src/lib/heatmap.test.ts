import { describe, expect, it } from "vitest";
import { buildHeatmap, formatSpan, isoDay, levelOf } from "./heatmap";

describe("heatmap geometry", () => {
  it("空序列返回空矩阵，但仍保留总量", () => {
    expect(buildHeatmap([])).toEqual({ weeks: [], max: 0, total: 0 });
  });

  it("每列 7 格，且按周一对齐", () => {
    // 2026-10-05 是周一
    const { weeks } = buildHeatmap([{ day: "2026-10-05", value: 10 }], {
      from: "2026-10-05",
      to: "2026-10-05"
    });
    expect(weeks).toHaveLength(1);
    expect(weeks[0]).toHaveLength(7);
    expect(weeks[0][0].day).toBe("2026-10-05");
    expect(weeks[0][1].day).toBeNull();
    expect(weeks[0][1].outside).toBe(true);
  });

  it("起始日不是周一时，前面的格子补空且标记为范围外", () => {
    // 2026-10-08 是周四
    const { weeks } = buildHeatmap([{ day: "2026-10-08", value: 5 }], {
      from: "2026-10-08",
      to: "2026-10-08"
    });
    expect(weeks[0][0]).toEqual({ day: null, value: 0, level: 0, outside: true });
    expect(weeks[0][3].day).toBe("2026-10-08");
  });

  it("跨月连续铺格，缺失日期按 0 处理", () => {
    const { weeks, total } = buildHeatmap(
      [
        { day: "2026-09-29", value: 100 },
        { day: "2026-10-02", value: 50 }
      ],
      { from: "2026-09-28", to: "2026-10-04" }
    );
    expect(total).toBe(150);
    const days = weeks.flat().filter((cell) => cell.day);
    expect(days).toHaveLength(7);
    expect(days.find((c) => c.day === "2026-09-30")?.value).toBe(0);
  });

  it("全零序列不产生伪高亮", () => {
    const { weeks, max } = buildHeatmap(
      [
        { day: "2026-10-05", value: 0 },
        { day: "2026-10-06", value: 0 }
      ],
      { from: "2026-10-05", to: "2026-10-06" }
    );
    expect(max).toBe(0);
    expect(weeks.flat().every((cell) => cell.level === 0)).toBe(true);
  });

  it("分档用对数，长尾不会被压成同一档", () => {
    expect(levelOf(0, 1000)).toBe(0);
    expect(levelOf(1, 1000)).toBe(1);
    expect(levelOf(1000, 1000)).toBe(4);
    // 线性四分位下 50/1000（5%）只会是第一档；对数下落在第三档
    expect(levelOf(50, 1000)).toBe(3);
    // 500/1000 的对数比是 0.90，落在最后一档
    expect(levelOf(500, 1000)).toBe(4);
  });

  it("isoDay 按 UTC 切日，不受本地时区影响", () => {
    expect(isoDay(new Date(Date.UTC(2026, 9, 5, 23, 30)))).toBe("2026-10-05");
  });

  it("跨度文案：分钟、小时、天", () => {
    expect(formatSpan(null)).toBeNull();
    expect(formatSpan(0)).toBeNull();
    expect(formatSpan(90_000)).toBe("2 分");
    expect(formatSpan(3 * 3_600_000)).toBe("3.0 小时");
    expect(formatSpan(72 * 3_600_000)).toBe("3.0 天");
  });
});
