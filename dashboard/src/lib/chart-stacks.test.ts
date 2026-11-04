import { describe, expect, test } from "vitest";
import { areaBetweenPath, stackedPoints } from "./chart";

describe("stackedPoints", () => {
  test("各层上沿单调递增，且最上层等于总量高度", () => {
    const layers = stackedPoints(
      [
        [10, 20],
        [30, 10]
      ],
      1000,
      180
    );
    expect(layers).toHaveLength(2);
    // 底层上沿 = 第一层，最上层上沿 = 两层之和
    expect(layers[1][0].y).toBeLessThan(layers[0][0].y);
    const totalTops = layers[1];
    const onlyLayer = stackedPoints([[40, 30]], 1000, 180)[0];
    expect(totalTops[0].y).toBeCloseTo(onlyLayer[0].y, 6);
    expect(totalTops[1].y).toBeCloseTo(onlyLayer[1].y, 6);
  });

  test("空输入与单点不炸", () => {
    expect(stackedPoints([], 100, 100)).toEqual([]);
    const single = stackedPoints([[5], [5]], 100, 100);
    expect(single).toHaveLength(2);
    expect(single[1][0].x).toBe(50);
    expect(single[1][0].y).toBeLessThan(single[0][0].y);
  });

  test("负值与缺位按 0 处理，不把层压歪", () => {
    const layers = stackedPoints(
      [[10, -5], [undefined, 10]] as unknown as number[][],
      100,
      100
    );
    // -5 与 undefined 都按 0：那一列的层高落回基线，上层恰好贴顶
    expect(layers[0][1].y).toBe(100);
    expect(layers[1][1].y).toBe(layers[1][0].y);
  });
});

describe("areaBetweenPath", () => {
  test("上沿与下沿等长才成形", () => {
    const top = [
      { x: 0, y: 10 },
      { x: 100, y: 20 }
    ];
    const bottom = [
      { x: 0, y: 50 },
      { x: 100, y: 60 }
    ];
    const d = areaBetweenPath(top, bottom);
    expect(d.startsWith("M0,10")).toBe(true);
    expect(d.endsWith("Z")).toBe(true);
    expect(d).toContain("L100,60 L0,50");
    expect(areaBetweenPath(top, [])).toBe("");
  });
});
