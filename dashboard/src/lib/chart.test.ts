import { describe, expect, it } from "vitest";
import { areaPath, barWidthPercent, linePath, niceCeiling, scaleSeries } from "./chart";

describe("chart geometry", () => {
  it("零值贴底，最大值贴顶（留出 6% 余量）", () => {
    const points = scaleSeries([0, 100], 100, 100);
    expect(points[0]).toEqual({ x: 0, y: 100 });
    expect(points[1].y).toBeCloseTo(6, 5);
  });

  it("全零序列不除零", () => {
    const points = scaleSeries([0, 0, 0], 90, 60);
    expect(points).toHaveLength(3);
    expect(points.every((p) => Number.isFinite(p.y) && p.y === 60)).toBe(true);
  });

  it("单点居中，不出现 NaN", () => {
    // 只有一个值时 max 就是它自己：贴顶（留 6% 余量），水平居中
    expect(scaleSeries([5], 100, 50)).toEqual([{ x: 50, y: 3 }]);
  });

  it("空序列返回空路径", () => {
    expect(scaleSeries([], 10, 10)).toEqual([]);
    expect(linePath([])).toBe("");
    expect(areaPath([], 10)).toBe("");
  });

  it("面积路径闭合到底边", () => {
    const path = areaPath(scaleSeries([1, 2], 100, 100), 100);
    expect(path.startsWith("M")).toBe(true);
    expect(path.endsWith("Z")).toBe(true);
    expect(path).toContain("L100,100");
  });

  it("纵轴上限取整到 1/2/5 × 10^n", () => {
    expect(niceCeiling(0)).toBe(0);
    expect(niceCeiling(7)).toBe(10);
    expect(niceCeiling(12)).toBe(20);
    expect(niceCeiling(41)).toBe(50);
    expect(niceCeiling(600)).toBe(1000);
  });

  it("条形宽度：零为 0，非零最小 2%", () => {
    expect(barWidthPercent(0, 100)).toBe(0);
    expect(barWidthPercent(1, 1_000_000)).toBe(2);
    expect(barWidthPercent(50, 100)).toBe(50);
    expect(barWidthPercent(200, 100)).toBe(100);
  });
});
