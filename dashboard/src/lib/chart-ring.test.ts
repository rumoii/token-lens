import { describe, expect, it } from "vitest";
import { arcDash, ringSegments } from "./chart";

describe("donut geometry", () => {
  it("全零序列返回空段，不画伪影", () => {
    expect(ringSegments([0, 0, 0, 0])).toEqual([]);
    expect(ringSegments([])).toEqual([]);
  });

  it("零值段被跳过，且不占角度", () => {
    const segments = ringSegments([10, 0, 10, 0]);
    expect(segments).toHaveLength(2);
    expect(segments.map((s) => s.index)).toEqual([0, 2]);
    // 两段各占一半（扣掉留白）
    expect(segments[0].share).toBeCloseTo(0.5, 6);
    expect(segments[1].share).toBeCloseTo(0.5, 6);
  });

  it("单段时占满 360°，不留缝", () => {
    const [only] = ringSegments([42]);
    expect(only.startDeg).toBe(0);
    expect(only.endDeg).toBeCloseTo(360, 6);
  });

  it("各段角度之和加上留白等于 360°", () => {
    const segments = ringSegments([1, 2, 3, 4], { gapDeg: 2 });
    const sweep = segments.reduce((sum, s) => sum + (s.endDeg - s.startDeg), 0);
    expect(sweep + 2 * segments.length).toBeCloseTo(360, 6);
  });

  it("负数与非法值按 0 处理，不制造负角度", () => {
    const segments = ringSegments([-5, 10, Number.NaN, 10]);
    expect(segments).toHaveLength(2);
    expect(segments.every((s) => s.endDeg > s.startDeg)).toBe(true);
  });

  it("弧长换算与半径一致：整圈时 dash 等于周长", () => {
    const radius = 60;
    const circumference = 2 * Math.PI * radius;
    const full = arcDash(0, 360, radius);
    expect(full.dash).toBeCloseTo(circumference, 6);
    expect(full.gap).toBeCloseTo(0, 6);

    const half = arcDash(0, 180, radius);
    expect(half.dash).toBeCloseTo(circumference / 2, 6);
    expect(half.gap).toBeCloseTo(circumference / 2, 6);
  });
});
