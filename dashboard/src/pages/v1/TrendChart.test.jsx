import React from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { buildBuckets, TrendChart } from "./TrendChart.jsx";
import { TokenFormatContext } from "../../ui/foundation/TokenFormatProvider.jsx";

const axis = { granularity: "day", from: "2026-10-20", to: "2026-10-20" };
const rows = (costs) => costs.map((cost_usd, i) => ({ bucket: axis.from, key: `tool-${i}`, gross_tokens: 100, cost_usd }));

describe("趋势图金额", () => {
  it.each([
    ["全部未知", [null, null], null],
    ["部分未知", [null, "1.25", "0.75"], 2],
    ["全部已知", ["1.25", "0.75"], 2],
    ["已知零", [null, "0.000000"], 0]
  ])("%s 的桶保留金额语义", (_, costs, expected) => {
    expect(buildBuckets(rows(costs), axis)[0].cost).toBe(expected);
  });

  it("全部未定价时悬停提示显示未定价", () => {
    const buckets = buildBuckets(rows([null]), axis);
    render(<TrendChart buckets={buckets} order={["tool-0"]} granularity="day" colorOf={() => "gray"} />);
    fireEvent.focus(screen.getByRole("group"));
    expect(screen.getByRole("tooltip")).toHaveTextContent("未定价");
    expect(screen.getByRole("tooltip")).not.toHaveTextContent("$0.00");
  });

  it("坐标轴、平均值和提示中的用量遵循英文单位", () => {
    const buckets = buildBuckets([{ bucket: axis.from, key: "codex", gross_tokens: 1200000, cost_usd: null }], axis);
    render(<TokenFormatContext.Provider value={{ unitSystem: "english" }}>
      <TrendChart buckets={buckets} order={["codex"]} granularity="day" colorOf={() => "gray"} />
    </TokenFormatContext.Provider>);
    expect(screen.getByText("1M")).toBeInTheDocument();
    expect(screen.getByText("平均 1.2M")).toBeInTheDocument();
    fireEvent.focus(screen.getByRole("group"));
    expect(screen.getByRole("tooltip").textContent.match(/1\.2M/g)).toHaveLength(2);
  });
});
