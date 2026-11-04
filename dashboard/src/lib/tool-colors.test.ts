import { describe, expect, it } from "vitest";
import { assignToolColors, OTHER_COLOR, sortByToolOrder, toolOrder } from "./tool-colors";

const row = (source: string, first: string | null, records = 1) => ({ source, first_observed_at: first, records });

describe("toolOrder", () => {
  it("按第一次出现的先后排，没有记录的不参与", () => {
    expect(
      toolOrder([
        row("codex", "2026-10-18T00:00:00Z"),
        row("dsh", "2026-10-17T01:00:00Z"),
        row("claude", "2026-10-17T02:00:00Z"),
        row("zed", null, 0)
      ])
    ).toEqual(["dsh", "claude", "codex"]);
  });

  it("时间相同或缺失时按 id，结果稳定", () => {
    expect(toolOrder([row("qwen", null), row("pi", "2026-10-17T00:00:00Z"), row("aider", "2026-10-17T00:00:00Z")])).toEqual([
      "aider",
      "pi",
      "qwen"
    ]);
  });
});

describe("assignToolColors", () => {
  it("依次占槽位，第 9 个起用其他色", () => {
    const ids = ["a", "b", "c", "d", "e", "f", "g", "h", "i"];
    const map = assignToolColors(ids);
    expect(map.get("a")).toBe("var(--lens-cat-1)");
    expect(map.get("h")).toBe("var(--lens-cat-8)");
    expect(map.get("i")).toBe(OTHER_COLOR);
  });

  it("颜色只看出现顺序，与用量排名无关", () => {
    const order = toolOrder([row("dsh", "2026-10-17T00:00:00Z"), row("codex", "2026-10-18T00:00:00Z")]);
    // 不管哪个周期里 codex 用得更多，dsh 永远是 1 号色
    expect(assignToolColors(order).get("dsh")).toBe("var(--lens-cat-1)");
  });
});

describe("sortByToolOrder", () => {
  it("按固定顺序排，不认识的排最后", () => {
    expect(sortByToolOrder(["new", "codex", "dsh"], ["dsh", "codex"])).toEqual(["dsh", "codex", "new"]);
  });
});
