import { describe, expect, it } from "vitest";
import { isStroked, markShapes } from "./brand-mark.js";

describe("markShapes", () => {
  it("大尺寸是四根柱子加高光，只有一根强调", () => {
    const shapes = markShapes();
    expect(shapes.filter((s) => s.type === "rect")).toHaveLength(4);
    expect(shapes.some((s) => s.role === "glint")).toBe(true);
    expect(shapes.filter((s) => s.role === "accent")).toHaveLength(1);
  });

  it("小尺寸去掉高光，三根更粗的柱子", () => {
    const small = markShapes({ small: true });
    const large = markShapes();
    expect(small.filter((s) => s.type === "rect")).toHaveLength(3);
    expect(small.some((s) => s.role === "glint")).toBe(false);
    expect(small[0].attrs.strokeWidth).toBeGreaterThan(large[0].attrs.strokeWidth);
  });

  it("柱子都落在镜片里面、同一条基线上", () => {
    for (const small of [false, true]) {
      const bars = markShapes({ small }).filter((s) => s.type === "rect");
      const bottoms = new Set(bars.map((b) => b.attrs.y + b.attrs.height));
      expect(bottoms.size).toBe(1);
      for (const { attrs: a } of bars) {
        for (const [x, y] of [[a.x, a.y], [a.x + a.width, a.y], [a.x, a.y + a.height], [a.x + a.width, a.y + a.height]]) {
          expect(Math.hypot(x - 16, y - 16)).toBeLessThan(10.5);
        }
      }
    }
  });

  it("环和高光描边，柱子填充", () => {
    expect(isStroked("ring")).toBe(true);
    expect(isStroked("glint")).toBe(true);
    expect(isStroked("bar")).toBe(false);
    expect(isStroked("accent")).toBe(false);
  });
});
